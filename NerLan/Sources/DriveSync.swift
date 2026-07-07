import CryptoKit
import Foundation

/// Last-writer-wins subscription state for one podcast feed (keyed by feed id in
/// `podcast-subs.json`). Drive sync merges these by newest `ts`, so an unsubscribe
/// — and a later re-subscribe — propagate across devices, which a plain union-merge
/// of the feed list can't express (it would keep re-adding a removed show). Field
/// names match the Android `SubEntry` so the ledger file is wire-compatible.
struct PodcastSubEntry: Codable, Equatable {
    let subscribed: Bool
    let ts: Int64   // epoch milliseconds (matches Android's Long)
}

/// Syncs favorites, AI study content, listening stats, and podcast subscriptions
/// to the user's Google Drive **appDataFolder** — a hidden, app-private folder in
/// their own Drive, with no developer-hosted backend. It's the bridge to the
/// Android app, which already syncs into the same folder (see `DriveAuth`).
///
/// This sits *beside* `ICloudSync`/`CloudKVStore`, not in place of them: it's an
/// opt-in second backend (Settings toggle `syncToDrive`). Both backends mirror the
/// same local JSON source-of-truth in `Documents`, so they're independent — turning
/// Drive on or off never changes the iCloud behavior. Audio is never synced.
///
/// Sync model (no server-side change feed, so it runs on launch / sign-in / a
/// debounced "a local thing changed"):
///  - metadata (favorites, programs, AI index): union-merge by id, last write wins.
///    Additions propagate; deletions don't (a backup tradeoff, like the file sync).
///  - content files (transcripts/handouts/cues/translations): write-once, so copy
///    whichever side is missing it.
///  - listening stats: one blob per device, summed on read (a G-counter).
///  - podcast subs: union-merge feeds + a last-writer-wins subscription ledger.
///
/// The wire format is Android's exact file names + JSON. The only field-name
/// divergence is `coverUrl` (Android) vs `coverURL` (iOS, which has no CodingKeys),
/// bridged by the `Wire*` DTOs below; every other field already matches.
@MainActor
final class DriveSync: ObservableObject {
    static let shared = DriveSync()

    /// The signed-in Google account label, or nil when signed out.
    @Published private(set) var accountEmail: String?
    /// Human-readable last-sync status for the Settings screen.
    @Published private(set) var status: String?

    private let auth = DriveAuth()
    private var isSyncing = false
    private var debounceTask: Task<Void, Never>?

    private init() {
        accountEmail = auth.email
    }

    var isSignedIn: Bool { auth.isSignedIn }

    // MARK: - Sign in / out

    /// Interactive browser sign-in; on success enables the toggle and kicks a sync.
    func signIn() async {
        status = "登入中…"
        do {
            try await auth.signIn()
            accountEmail = auth.email
            // Flipping the toggle on triggers the first sync via its didSet.
            SettingsStore.shared.syncToDrive = true
        } catch is DriveAuth.ReauthRequired {
            status = "登入已取消"
        } catch {
            status = "登入失敗：\(error.localizedDescription)"
        }
    }

    func signOut() {
        auth.signOut()
        accountEmail = nil
        status = nil
        debounceTask?.cancel()
        SettingsStore.shared.syncToDrive = false
    }

    // MARK: - Sync triggers

    /// Run a full sync now (no-op unless sync is on, signed in, and idle).
    func syncNow() {
        guard SettingsStore.shared.syncToDrive, auth.isSignedIn, !isSyncing else { return }
        Task { await runSync() }
    }

    /// Debounced auto-sync after a local change (favoriting, a transcript finishing,
    /// listening time, a subscription). Coalesces a burst into one sync ~2.5s after
    /// the last change. No-op unless sync is on and signed in.
    ///
    /// `nonisolated static` so any store can fire it regardless of its own actor
    /// isolation (e.g. `FavoritesStore`, which isn't `@MainActor`); the work hops to
    /// the main actor.
    nonisolated static func requestSync() {
        Task { @MainActor in shared.scheduleDebouncedSync() }
    }

    private func scheduleDebouncedSync() {
        guard SettingsStore.shared.syncToDrive, auth.isSignedIn else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    /// Cancel a pending debounced sync (e.g. the toggle was turned off).
    func cancelPending() { debounceTask?.cancel() }

    private func runSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        status = "同步中…"
        defer { isSyncing = false }
        do {
            let token = try await auth.accessToken()
            let result = try await performSync(token: token)
            status = result.skipped.isEmpty
                ? "已同步（↑\(result.pushed) ↓\(result.pulled)）"
                : "已同步（↑\(result.pushed) ↓\(result.pulled)），\(result.skipped.count) 個檔案無法解析，已略過"
            if result.pulled > 0 { reloadStores() }
        } catch is DriveAuth.ReauthRequired {
            accountEmail = auth.email   // nil after the failed refresh signed us out
            status = "需要重新登入 Google"
        } catch {
            status = "同步失敗：\(error.localizedDescription)"
        }
    }

    /// Re-read every store from the JSON files a pull just rewrote.
    private func reloadStores() {
        FavoritesStore.shared.reload()
        AIContentStore.shared.reloadIndex()
        PodcastStore.shared.reload()
        ListeningStatsStore.shared.reloadDrivePeers()
    }

    // MARK: - Local file layout (the source of truth both backends mirror)

    private nonisolated var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private nonisolated var favoritesURL: URL { documents.appendingPathComponent("favorites.json") }
    private nonisolated var programsURL: URL { documents.appendingPathComponent("favorite-programs.json") }
    private nonisolated var aiDir: URL { documents.appendingPathComponent("ai", isDirectory: true) }
    private nonisolated var aiIndexURL: URL { aiDir.appendingPathComponent("index.json") }
    private nonisolated var podcastsURL: URL { documents.appendingPathComponent("podcasts.json") }
    private nonisolated var podcastSubsURL: URL { documents.appendingPathComponent("podcast-subs.json") }
    private nonisolated var listeningStatsURL: URL { documents.appendingPathComponent("listening-stats.json") }
    private nonisolated var statsPeersDir: URL { documents.appendingPathComponent("stats-peers", isDirectory: true) }
    private nonisolated var stateURL: URL { documents.appendingPathComponent("drive-sync-state.json") }

    // MARK: - Sync engine

    /// Per-file change tokens persisted between syncs: the remote's Drive
    /// `modifiedTime` (which advances when *any* device writes the file) and the
    /// SHA-256 of the bytes this device last wrote locally. When both still match,
    /// neither side changed and the file is skipped — no download, no upload. The
    /// first sync after install (no state) treats everything as changed.
    private struct FileState: Codable {
        var remoteModifiedTime: String?
        var localHash: String?
    }
    private struct SyncState: Codable {
        var files: [String: FileState] = [:]
    }
    private struct SyncOutcome {
        var pushed = 0
        var pulled = 0
        var state: [String: FileState] = [:]
    }

    /// A sync artifact that exists but doesn't decode (truncated upload, wire-format
    /// drift). Thrown instead of merging: treating it as empty would make the merge
    /// "win" with only the other side's entries and silently wipe the corrupt side.
    /// The file is skipped for this run and retried on the next sync.
    private struct CorruptSyncData: Error { let file: String }

    private nonisolated func performSync(token: String) async throws -> (pushed: Int, pulled: Int, skipped: [String]) {
        let remote = try await listFiles(token: token)
        let prev = loadState()
        var pushed = 0, pulled = 0
        var skipped: [String] = []
        var newState = prev.files

        func apply(_ outcome: SyncOutcome) {
            pushed += outcome.pushed
            pulled += outcome.pulled
            for (key, value) in outcome.state { newState[key] = value }
        }
        // A corrupt file skips just that artifact; anything else still aborts the run.
        func run(_ step: () async throws -> SyncOutcome) async throws {
            do { apply(try await step()) }
            catch let bad as CorruptSyncData { skipped.append(bad.file) }
        }

        // Metadata files run sequentially — they're tiny single files. Content
        // files (potentially many) parallelize inside their own step.
        try await run { try await self.syncFavorites(token, remote, prev.files["favorites.json"]) }
        try await run { try await self.syncPrograms(token, remote, prev.files["favorite-programs.json"]) }
        try await run { try await self.syncAIIndex(token, remote, prev.files["ai-index.json"]) }
        try await run { try await self.syncPodcasts(token, remote, prev) }
        apply(try await syncContentFiles(token, remote))
        // Stats are isolated so a hiccup there can't abort the favorites/AI sync.
        apply((try? await syncStats(token, remote, prev)) ?? SyncOutcome())

        saveState(SyncState(files: newState))
        return (pushed, pulled, skipped)
    }

    /// Sync one whole-file JSON artifact. `merge` is pure and returns the canonical
    /// **local-format** bytes (iOS `coverURL`) and **remote-format** bytes (Android
    /// `coverUrl`) — identical for files with no field-name divergence. The
    /// read/write/compare/skip mechanics live here, mirroring Android's
    /// `syncMetadataFile`.
    private nonisolated func syncMergedFile(
        token: String,
        remote: [String: DriveFile],
        prev: FileState?,
        driveName: String,
        localURL: URL,
        merge: (_ localBytes: Data?, _ remoteBytes: Data?) throws -> (local: Data, remote: Data)
    ) async throws -> SyncOutcome {
        let rf = remote[driveName]
        let localBytes = try? Data(contentsOf: localURL)
        let localHash = sha256(localBytes)
        let remoteChanged = rf?.modifiedTime != prev?.remoteModifiedTime
        let localChanged = localHash != prev?.localHash

        if rf == nil && localBytes == nil { return SyncOutcome() }   // nothing anywhere
        if !remoteChanged && !localChanged { return SyncOutcome() }  // in sync since last time

        let remoteBytes = rf != nil ? try await download(token: token, id: rf!.id) : nil
        let merged = try merge(localBytes, remoteBytes)
        var pushed = 0, pulled = 0
        if merged.local != localBytes {
            try? FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? merged.local.write(to: localURL)
            pulled = 1
        }
        var modifiedTime = rf?.modifiedTime
        if merged.remote != remoteBytes {
            modifiedTime = try await upsert(
                token: token, name: driveName, existingId: rf?.id, data: merged.remote, mime: "application/json")
            pushed = 1
        }
        return SyncOutcome(pushed: pushed, pulled: pulled,
                           state: [driveName: FileState(remoteModifiedTime: modifiedTime, localHash: sha256(merged.local))])
    }

    private nonisolated func syncFavorites(_ token: String, _ remote: [String: DriveFile], _ prev: FileState?) async throws -> SyncOutcome {
        try await syncMergedFile(token: token, remote: remote, prev: prev,
                                 driveName: "favorites.json", localURL: favoritesURL) { local, remoteBytes in
            let merged = Self.mergeById(local: try Self.decodeRecords(local, wire: false, file: "favorites.json (local)"),
                                        remote: try Self.decodeRecords(remoteBytes, wire: true, file: "favorites.json")) { $0.id }
            return (Self.encodeRecords(merged, wire: false), Self.encodeRecords(merged, wire: true))
        }
    }

    private nonisolated func syncPrograms(_ token: String, _ remote: [String: DriveFile], _ prev: FileState?) async throws -> SyncOutcome {
        // Program has no URL-casing divergence — local and remote bytes are identical.
        try await syncMergedFile(token: token, remote: remote, prev: prev,
                                 driveName: "favorite-programs.json", localURL: programsURL) { local, remoteBytes in
            let merged = Self.mergeById(local: try Self.decodeList(Program.self, local, file: "favorite-programs.json (local)"),
                                        remote: try Self.decodeList(Program.self, remoteBytes, file: "favorite-programs.json")) { $0.programId }
            let data = (try? JSONEncoder().encode(merged)) ?? Data("[]".utf8)
            return (data, data)
        }
    }

    private nonisolated func syncAIIndex(_ token: String, _ remote: [String: DriveFile], _ prev: FileState?) async throws -> SyncOutcome {
        try await syncMergedFile(token: token, remote: remote, prev: prev,
                                 driveName: "ai-index.json", localURL: aiIndexURL) { local, remoteBytes in
            // local overrides remote on key conflict (matches Android).
            var merged = try Self.decodeRecordMap(remoteBytes, wire: true, file: "ai-index.json")
            for (key, value) in try Self.decodeRecordMap(local, wire: false, file: "ai-index.json (local)") { merged[key] = value }
            return (Self.encodeRecordMap(merged, wire: false), Self.encodeRecordMap(merged, wire: true))
        }
    }

    /// Listening stats: mirror this device's blob up (only when changed) and pull
    /// every other device's down (only those whose modifiedTime advanced). The
    /// merged view is summed by `ListeningStatsStore` (a G-counter).
    private nonisolated func syncStats(_ token: String, _ remote: [String: DriveFile], _ prev: SyncState) async throws -> SyncOutcome {
        guard let deviceId = UserDefaults.standard.string(forKey: "listeningStatsDeviceId") else { return SyncOutcome() }
        let ownName = "stats-\(deviceId).json"
        var state: [String: FileState] = [:]
        var pushed = 0, pulled = 0

        let ownBytes = try? Data(contentsOf: listeningStatsURL)
        let ownHash = sha256(ownBytes)
        // Only this device writes its own blob, so a matching local hash means the
        // remote copy is already current — skip the upload.
        if let ownBytes, ownHash != prev.files[ownName]?.localHash {
            let mt = try await upsert(token: token, name: ownName, existingId: remote[ownName]?.id,
                                      data: ownBytes, mime: "application/json")
            state[ownName] = FileState(remoteModifiedTime: mt, localHash: ownHash)
            pushed += 1
        }

        try? FileManager.default.createDirectory(at: statsPeersDir, withIntermediateDirectories: true)
        for rf in remote.values where rf.name != ownName && rf.name.hasPrefix("stats-") && rf.name.hasSuffix(".json") {
            if rf.modifiedTime != prev.files[rf.name]?.remoteModifiedTime {
                let bytes = try await download(token: token, id: rf.id)
                try? bytes.write(to: statsPeersDir.appendingPathComponent(rf.name))
                state[rf.name] = FileState(remoteModifiedTime: rf.modifiedTime, localHash: nil)
                pulled += 1
            }
        }
        return SyncOutcome(pushed: pushed, pulled: pulled, state: state)
    }

    /// Podcast subscriptions: union-merge the feed data and LWW-merge the
    /// subscription ledger, then keep only feeds the ledger marks subscribed (a
    /// missing entry defaults to subscribed, for shows added before the ledger
    /// existed). The two files are coupled, so they're skipped/merged as a unit but
    /// uploaded individually. Ports Android's `syncPodcasts`.
    private nonisolated func syncPodcasts(_ token: String, _ remote: [String: DriveFile], _ prev: SyncState) async throws -> SyncOutcome {
        let ledgerName = "podcast-subs.json", feedsName = "podcasts.json"
        let ledgerRf = remote[ledgerName], feedsRf = remote[feedsName]
        let ledgerLocal = try? Data(contentsOf: podcastSubsURL)
        let feedsLocal = try? Data(contentsOf: podcastsURL)
        let ledgerPrev = prev.files[ledgerName], feedsPrev = prev.files[feedsName]

        let anyExists = ledgerRf != nil || feedsRf != nil || ledgerLocal != nil || feedsLocal != nil
        let changed =
            ledgerRf?.modifiedTime != ledgerPrev?.remoteModifiedTime ||
            feedsRf?.modifiedTime != feedsPrev?.remoteModifiedTime ||
            sha256(ledgerLocal) != ledgerPrev?.localHash ||
            sha256(feedsLocal) != feedsPrev?.localHash
        if !anyExists || !changed { return SyncOutcome() }

        let ledgerRemote = ledgerRf != nil ? try await download(token: token, id: ledgerRf!.id) : nil
        let feedsRemote = feedsRf != nil ? try await download(token: token, id: feedsRf!.id) : nil
        let mergedLedger = Self.mergeLedger(try Self.decodeLedger(ledgerLocal, file: "podcast-subs.json (local)"),
                                            try Self.decodeLedger(ledgerRemote, file: "podcast-subs.json"))
        let unionFeeds = Self.mergeById(local: try Self.decodeFeeds(feedsLocal, wire: false, file: "podcasts.json (local)"),
                                        remote: try Self.decodeFeeds(feedsRemote, wire: true, file: "podcasts.json")) { $0.id }
        let subscribed = unionFeeds.filter { mergedLedger[$0.id]?.subscribed ?? true }

        let ledgerBytes = Self.encodeLedger(mergedLedger)
        let feedsLocalBytes = Self.encodeFeeds(subscribed, wire: false)
        let feedsRemoteBytes = Self.encodeFeeds(subscribed, wire: true)
        var pushed = 0, pulled = 0
        if ledgerBytes != ledgerLocal { try? ledgerBytes.write(to: podcastSubsURL); pulled += 1 }
        if feedsLocalBytes != feedsLocal { try? feedsLocalBytes.write(to: podcastsURL); pulled += 1 }
        var ledgerMt = ledgerRf?.modifiedTime
        var feedsMt = feedsRf?.modifiedTime
        if ledgerBytes != ledgerRemote {
            ledgerMt = try await upsert(token: token, name: ledgerName, existingId: ledgerRf?.id, data: ledgerBytes, mime: "application/json")
            pushed += 1
        }
        if feedsRemoteBytes != feedsRemote {
            feedsMt = try await upsert(token: token, name: feedsName, existingId: feedsRf?.id, data: feedsRemoteBytes, mime: "application/json")
            pushed += 1
        }
        return SyncOutcome(pushed: pushed, pulled: pulled, state: [
            ledgerName: FileState(remoteModifiedTime: ledgerMt, localHash: sha256(ledgerBytes)),
            feedsName: FileState(remoteModifiedTime: feedsMt, localHash: sha256(feedsLocalBytes)),
        ])
    }

    /// Content files (write-once): push local-only up, pull remote-only down, with
    /// bounded concurrency. Already-synced files transfer nothing.
    private nonisolated func syncContentFiles(_ token: String, _ remote: [String: DriveFile]) async throws -> SyncOutcome {
        let local = contentFiles()
        let toPush = local.filter { remote[$0.key] == nil }.map { ($0.key, $0.value) }
        let toPull = remote.values.filter { Self.isContentName($0.name) && local[$0.name] == nil }

        try await runLimited(toPush, limit: 6) { item in
            let (name, url) = item
            guard let data = try? Data(contentsOf: url) else { return }
            _ = try await self.upsert(token: token, name: name, existingId: nil, data: data, mime: Self.contentMime(name))
        }
        try await runLimited(Array(toPull), limit: 6) { rf in
            let data = try await self.download(token: token, id: rf.id)
            self.writeContent(name: rf.name, data: data)
        }
        return SyncOutcome(pushed: toPush.count, pulled: toPull.count)
    }

    // MARK: - Content-file mapping (drive name <-> local ai/ path)

    private nonisolated func contentFiles() -> [String: URL] {
        var out: [String: URL] = [:]
        let kinds: [(sub: String, prefix: String, ext: String)] = [
            ("transcripts", "transcript-", "txt"),
            ("handouts", "handout-", "html"),
            ("cues", "cues-", "json"),
            ("translations", "translation-", "json"),
        ]
        for kind in kinds {
            let dir = aiDir.appendingPathComponent(kind.sub, isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == kind.ext {
                let id = file.deletingPathExtension().lastPathComponent
                out["\(kind.prefix)\(id).\(kind.ext)"] = file
            }
        }
        return out
    }

    private nonisolated static func isContentName(_ name: String) -> Bool {
        (name.hasPrefix("transcript-") && name.hasSuffix(".txt")) ||
        (name.hasPrefix("handout-") && name.hasSuffix(".html")) ||
        (name.hasPrefix("cues-") && name.hasSuffix(".json")) ||
        (name.hasPrefix("translation-") && name.hasSuffix(".json"))
    }

    private nonisolated static func contentMime(_ name: String) -> String {
        if name.hasSuffix(".html") { return "text/html" }
        if name.hasSuffix(".json") { return "application/json" }
        return "text/plain"
    }

    private nonisolated func writeContent(name: String, data: Data) {
        let mapping: [(prefix: String, suffix: String, sub: String, ext: String)] = [
            ("transcript-", ".txt", "transcripts", "txt"),
            ("handout-", ".html", "handouts", "html"),
            ("cues-", ".json", "cues", "json"),
            ("translation-", ".json", "translations", "json"),
        ]
        for map in mapping where name.hasPrefix(map.prefix) && name.hasSuffix(map.suffix) {
            let id = String(name.dropFirst(map.prefix.count).dropLast(map.suffix.count))
            // Drive content is keyed by episode id only; guard against junk ids the
            // way AIContentStore.cleanupMalformedLocalContent does.
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
            let dir = aiDir.appendingPathComponent(map.sub, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent("\(id).\(map.ext)"))
            return
        }
    }

    // MARK: - Merge helpers

    private nonisolated static func mergeById<T>(local: [T], remote: [T], id: (T) -> String) -> [T] {
        var map: [String: T] = [:]
        for item in remote { map[id(item)] = item }
        for item in local { map[id(item)] = item }   // local wins on conflict
        return map.values.sorted { id($0) < id($1) }
    }

    private nonisolated static func mergeLedger(_ a: [String: PodcastSubEntry], _ b: [String: PodcastSubEntry]) -> [String: PodcastSubEntry] {
        var out = a
        for (id, entry) in b where out[id] == nil || entry.ts > out[id]!.ts { out[id] = entry }
        return out
    }

    // MARK: - Codec helpers (iOS-native vs Android-wire)

    // A nil input (file absent) decodes as empty; present-but-undecodable bytes
    // throw `CorruptSyncData` so the caller skips this artifact instead of letting
    // an empty merge overwrite the other side.
    private nonisolated static func decodeList<T: Decodable>(_ type: T.Type, _ data: Data?, file: String) throws -> [T] {
        guard let data else { return [] }
        guard let list = try? JSONDecoder().decode([T].self, from: data) else { throw CorruptSyncData(file: file) }
        return list
    }

    private nonisolated static func decodeRecords(_ data: Data?, wire: Bool, file: String) throws -> [EpisodeRecord] {
        guard let data else { return [] }
        if wire {
            guard let list = try? JSONDecoder().decode([WireRecord].self, from: data) else { throw CorruptSyncData(file: file) }
            return list.map { $0.model }
        }
        guard let list = try? JSONDecoder().decode([EpisodeRecord].self, from: data) else { throw CorruptSyncData(file: file) }
        return list
    }

    private nonisolated static func encodeRecords(_ records: [EpisodeRecord], wire: Bool) -> Data {
        let encoder = JSONEncoder()
        if wire { return (try? encoder.encode(records.map { WireRecord($0) })) ?? Data("[]".utf8) }
        return (try? encoder.encode(records)) ?? Data("[]".utf8)
    }

    private nonisolated static func decodeRecordMap(_ data: Data?, wire: Bool, file: String) throws -> [String: EpisodeRecord] {
        guard let data else { return [:] }
        if wire {
            guard let map = try? JSONDecoder().decode([String: WireRecord].self, from: data) else { throw CorruptSyncData(file: file) }
            return map.mapValues { $0.model }
        }
        guard let map = try? JSONDecoder().decode([String: EpisodeRecord].self, from: data) else { throw CorruptSyncData(file: file) }
        return map
    }

    private nonisolated static func encodeRecordMap(_ map: [String: EpisodeRecord], wire: Bool) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if wire { return (try? encoder.encode(map.mapValues { WireRecord($0) })) ?? Data("{}".utf8) }
        return (try? encoder.encode(map)) ?? Data("{}".utf8)
    }

    private nonisolated static func decodeFeeds(_ data: Data?, wire: Bool, file: String) throws -> [PodcastFeed] {
        guard let data else { return [] }
        if wire {
            guard let list = try? JSONDecoder().decode([WireFeed].self, from: data) else { throw CorruptSyncData(file: file) }
            return list.map { $0.model }
        }
        guard let list = try? JSONDecoder().decode([PodcastFeed].self, from: data) else { throw CorruptSyncData(file: file) }
        return list
    }

    private nonisolated static func encodeFeeds(_ feeds: [PodcastFeed], wire: Bool) -> Data {
        let encoder = JSONEncoder()
        if wire { return (try? encoder.encode(feeds.map { WireFeed($0) })) ?? Data("[]".utf8) }
        return (try? encoder.encode(feeds)) ?? Data("[]".utf8)
    }

    private nonisolated static func decodeLedger(_ data: Data?, file: String) throws -> [String: PodcastSubEntry] {
        guard let data else { return [:] }
        guard let map = try? JSONDecoder().decode([String: PodcastSubEntry].self, from: data) else { throw CorruptSyncData(file: file) }
        return map
    }

    private nonisolated static func encodeLedger(_ ledger: [String: PodcastSubEntry]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(ledger)) ?? Data("{}".utf8)
    }

    // MARK: - Drive REST v3 (over URLSession)

    private struct DriveFile: Decodable { let id: String; let name: String; let modifiedTime: String? }
    private struct FileList: Decodable { let files: [DriveFile] }
    private struct UploadMeta: Encodable { let name: String; let parents: [String] }
    private struct UploadResult: Decodable { let id: String?; let modifiedTime: String? }

    private nonisolated func listFiles(token: String) async throws -> [String: DriveFile] {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        comps.queryItems = [
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "fields", value: "files(id,name,modifiedTime)"),
            .init(name: "pageSize", value: "1000"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, "list")
        let list = try JSONDecoder().decode(FileList.self, from: data)
        return Dictionary(list.files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated func download(token: String, id: String) async throws -> Data {
        var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(id)")!
        comps.queryItems = [.init(name: "alt", value: "media")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, "download")
        return data
    }

    /// Create the file (when `existingId` is nil) via a multipart/related upload, or
    /// replace its content with `PATCH uploadType=media`. Returns the file's new
    /// Drive `modifiedTime` (the change token stored for next sync), if present.
    private nonisolated func upsert(token: String, name: String, existingId: String?, data: Data, mime: String) async throws -> String? {
        let req: URLRequest
        let body: Data
        if let existingId {
            var comps = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/\(existingId)")!
            comps.queryItems = [.init(name: "uploadType", value: "media"), .init(name: "fields", value: "id,modifiedTime")]
            var r = URLRequest(url: comps.url!)
            r.httpMethod = "PATCH"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue(mime, forHTTPHeaderField: "Content-Type")
            req = r
            body = data
        } else {
            let boundary = "nerlan-\(UUID().uuidString)"
            var multipart = Data()
            let meta = (try? JSONEncoder().encode(UploadMeta(name: name, parents: ["appDataFolder"]))) ?? Data()
            multipart.append(Data("--\(boundary)\r\n".utf8))
            multipart.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            multipart.append(meta)
            multipart.append(Data("\r\n--\(boundary)\r\n".utf8))
            multipart.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
            multipart.append(data)
            multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
            var comps = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
            comps.queryItems = [.init(name: "uploadType", value: "multipart"), .init(name: "fields", value: "id,modifiedTime")]
            var r = URLRequest(url: comps.url!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req = r
            body = multipart
        }
        let (respData, resp) = try await URLSession.shared.upload(for: req, from: body)
        try Self.check(resp, "upload")
        return (try? JSONDecoder().decode(UploadResult.self, from: respData))?.modifiedTime
    }

    private nonisolated static func check(_ resp: URLResponse, _ op: String) throws {
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw DriveAuth.ReauthRequired() }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DriveSync", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Drive \(op) \(http.statusCode)"])
        }
    }

    // MARK: - State & misc

    private nonisolated func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    private nonisolated func saveState(_ state: SyncState) {
        try? JSONEncoder().encode(state).write(to: stateURL)
    }

    private nonisolated func sha256(_ data: Data?) -> String? {
        guard let data else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Run `op` over `items` with at most `limit` concurrent tasks. Any throw
    /// propagates (the sync fails and retries next pass), matching Android.
    private nonisolated func runLimited<T>(_ items: [T], limit: Int, _ op: @escaping (T) async throws -> Void) async throws {
        guard !items.isEmpty else { return }
        var index = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            func addNext() {
                guard index < items.count else { return }
                let item = items[index]
                index += 1
                group.addTask { try await op(item) }
            }
            for _ in 0..<min(limit, items.count) { addNext() }
            while try await group.next() != nil { addNext() }
        }
    }
}

// MARK: - Wire DTOs (Android `coverUrl` <-> iOS `coverURL`)

/// `EpisodeRecord` on the wire. iOS serializes `coverURL` (no CodingKeys); Android
/// emits `coverUrl`. This DTO carries Android's casing for Drive round-trips; every
/// other field already matches field-for-field (verified against the Android model).
private struct WireRecord: Codable {
    let id: String
    let title: String
    let playDate: String?
    let audio: String?
    let programId: String
    let programName: String
    let language: String
    let coverUrl: String?
    let attachments: [Attachment]?
    let durationSeconds: Int?
    let audioExt: String?
    let audioLocale: String?

    init(_ r: EpisodeRecord) {
        id = r.id; title = r.title; playDate = r.playDate; audio = r.audio
        programId = r.programId; programName = r.programName; language = r.language
        coverUrl = r.coverURL; attachments = r.attachments
        durationSeconds = r.durationSeconds; audioExt = r.audioExt; audioLocale = r.audioLocale
    }

    var model: EpisodeRecord {
        EpisodeRecord(id: id, title: title, playDate: playDate, audio: audio,
                      programId: programId, programName: programName, language: language,
                      coverURL: coverUrl, durationSeconds: durationSeconds, audioExt: audioExt,
                      audioLocale: audioLocale, attachments: attachments)
    }
}

/// `PodcastFeed` on the wire (same `coverUrl`/`coverURL` divergence, plus nested
/// `EpisodeRecord`s).
private struct WireFeed: Codable {
    let id: String
    let title: String
    let author: String?
    let description: String?
    let coverUrl: String?
    let language: String
    let episodes: [WireRecord]

    init(_ f: PodcastFeed) {
        id = f.id; title = f.title; author = f.author; description = f.description
        coverUrl = f.coverURL; language = f.language; episodes = f.episodes.map(WireRecord.init)
    }

    var model: PodcastFeed {
        PodcastFeed(id: id, title: title, author: author, description: description,
                    coverURL: coverUrl, language: language, episodes: episodes.map { $0.model })
    }
}
