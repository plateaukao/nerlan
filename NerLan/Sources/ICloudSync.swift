import Foundation

/// Mirrors the AI study content — transcripts and AI handouts, the only assets
/// that cost OpenAI credits to produce — into the app's iCloud container so they
/// survive reinstalls and show up on the user's other devices. Audio is
/// deliberately never synced (large, and re-downloadable for free from Channel+).
///
/// Local `Documents/ai/{transcripts,handouts,cues}/{id}.{ext}` stays the source
/// of truth: `AIContentStore` reads/writes there synchronously and the app works
/// fully with iCloud off. The *cloud* copy is laid out for humans browsing the
/// "NerLan" folder in Files — one readable folder per episode:
///
///     <programName> - <title> [<id>]/
///         transcript.txt
///         handout.html
///         cues.json         (sentence timestamps; rides with the transcript)
///         translation.json  (per-sentence translation; rides with the transcript)
///
/// The `[<id>]` suffix is how the pull side maps a folder back to the local
/// id-keyed file; the inner names are fixed ASCII so matching is immune to
/// Unicode-normalization surprises. Conflicts are a non-issue: content is
/// write-once (generated, then read-only unless explicitly regenerated), so
/// "already present locally wins".
final class ICloudSync {
    static let shared = ICloudSync()

    /// The artifact kinds and their names live in `AIContentKind`, shared with
    /// `AIContentStore` and `DriveSync` so the three layers can't drift.
    typealias Kind = AIContentKind

    /// Fired on the main thread after files are pulled down, so stores can
    /// refresh their `hasTranscript`/`hasHandout`-driven UI.
    var onDidPull: (() -> Void)?

    private let fm = FileManager.default
    private let localAIDir: URL
    /// All container reads/writes are serialized here, off the main thread —
    /// `url(forUbiquityContainerIdentifier:)` blocks on first use.
    private let queue = DispatchQueue(label: "com.danielkao.nerlan.icloudsync")
    private var query: NSMetadataQuery?

    private var containerResolved = false
    private var cachedContainer: URL?

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        localAIDir = docs.appendingPathComponent("ai", isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Start watching the container for files arriving from other devices.
    /// Idempotent. Bulk upload of existing local content is driven separately by
    /// `AIContentStore` (it owns the readable names).
    func start() {
        queue.async {
            self.cleanupLegacyLocked()
            self.cleanupContainerLocked()
        }
        DispatchQueue.main.async { self.startQuery() }
    }

    /// Stop watching. Leaves synced content in iCloud so a later re-enable (or
    /// another device) still has it.
    func stop() {
        DispatchQueue.main.async {
            guard let q = self.query else { return }
            q.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
            self.query = nil
        }
    }

    // MARK: - Outgoing (local -> iCloud)

    /// Copy one local artifact up into its episode folder, creating the folder
    /// (with a readable name) if it doesn't exist yet.
    func mirrorUp(_ kind: Kind, id: String, displayName: String?) {
        mirrorUpBatch([(kind, id, displayName)])
    }

    /// `mirrorUp` for many artifacts in one pass. The id→folder map is built
    /// from a single container-root scan and reused for every item — the
    /// launch-time bulk upload used to re-list the root (and `resourceValues`
    /// every entry) once per artifact, i.e. O(artifacts × folders) through the
    /// iCloud daemon just to conclude everything was already uploaded.
    func mirrorUpBatch(_ items: [(kind: Kind, id: String, displayName: String?)]) {
        queue.async {
            guard let root = self.cloudRootLocked() else { return }
            var folders = self.episodeFoldersLocked(root: root)
            for item in items {
                let source = self.localFile(item.kind, item.id)
                guard self.fm.fileExists(atPath: source.path) else { continue }
                let existingFolder = folders[item.id]
                // Content is write-once: if the cloud already has this artifact (as a
                // real file or a not-yet-downloaded ".<name>.icloud" placeholder),
                // don't re-upload it. Re-replacing on every launch is what spawned the
                // "transcript 2.txt" conflict duplicates. A changed artifact (e.g. a
                // re-translation) routes through `removeUp` first, so the cloud copy is
                // gone here and this proceeds to upload the new one.
                if let folder = existingFolder, self.cloudArtifactExists(folder: folder, kind: item.kind) {
                    continue
                }
                let folder = existingFolder
                    ?? root.appendingPathComponent(self.folderName(displayName: item.displayName, id: item.id), isDirectory: true)
                folders[item.id] = folder   // later artifacts of this episode reuse it
                try? self.fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let dest = folder.appendingPathComponent(item.kind.cloudFile)
                let coordinator = NSFileCoordinator()
                var err: NSError?
                coordinator.coordinate(writingItemAt: dest, options: .forReplacing, error: &err) { url in
                    try? self.fm.removeItem(at: url)
                    try? self.fm.copyItem(at: source, to: url)
                }
            }
        }
    }

    /// Every episode folder in the container, keyed by episode id — one scan.
    private func episodeFoldersLocked(root: URL) -> [String: URL] {
        var out: [String: URL] = [:]
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, let id = parsedId(fromFolderName: item.lastPathComponent) { out[id] = item }
        }
        return out
    }

    /// Whether `folder` already holds this `kind`'s artifact in iCloud — either the
    /// materialized file or its undownloaded ".<name>.icloud" placeholder.
    private func cloudArtifactExists(folder: URL, kind: Kind) -> Bool {
        let file = folder.appendingPathComponent(kind.cloudFile)
        let placeholder = folder.appendingPathComponent(".\(kind.cloudFile).icloud")
        return fm.fileExists(atPath: file.path) || fm.fileExists(atPath: placeholder.path)
    }

    /// Remove one artifact from its episode folder; drop the folder if it leaves
    /// the episode with nothing.
    func removeUp(_ kind: Kind, id: String) {
        queue.async {
            guard let root = self.cloudRootLocked(),
                  let folder = self.episodeFolderLocked(root: root, id: id) else { return }
            self.coordinatedRemove(folder.appendingPathComponent(kind.cloudFile))
            let remaining = (try? self.fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if remaining.isEmpty { self.coordinatedRemove(folder) }
        }
    }

    /// Remove every synced episode folder (mirrors `AIContentStore.clearAll`).
    func removeAllUp() {
        queue.async {
            guard let root = self.cloudRootLocked() else { return }
            for item in (try? self.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                self.coordinatedRemove(item)
            }
        }
    }

    // MARK: - Container resolution & helpers (call on `queue`)

    private func containerLocked() -> URL? {
        if !containerResolved {
            cachedContainer = fm.url(forUbiquityContainerIdentifier: nil)
            containerResolved = true
        }
        return cachedContainer
    }

    /// The container's `Documents` folder — what the user sees as "NerLan" in Files.
    private func cloudRootLocked() -> URL? {
        containerLocked()?.appendingPathComponent("Documents", isDirectory: true)
    }

    private func localFile(_ kind: Kind, _ id: String) -> URL {
        localAIDir.appendingPathComponent("\(kind.localSub)/\(id).\(kind.localExt)")
    }

    /// Find the existing episode folder for `id` regardless of its readable name.
    private func episodeFolderLocked(root: URL, id: String) -> URL? {
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir, parsedId(fromFolderName: item.lastPathComponent) == id { return item }
        }
        return nil
    }

    /// Drop the previous flat `ai/` layout from the container, if present.
    private func cleanupLegacyLocked() {
        guard let root = cloudRootLocked() else { return }
        let legacy = root.appendingPathComponent("ai", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) { coordinatedRemove(legacy) }
    }

    /// Heal two kinds of container garbage left by the old, buggy upload path,
    /// authoritatively (each device cleans its own ubiquity copy, so it converges
    /// across devices once they all run this build — unlike manual deletion, which
    /// just loses to another device re-uploading):
    ///   1. Folders whose name got truncated by the 255-byte limit so they no
    ///      longer map to an episode id (`parsedId` returns nil — the "[id]" suffix
    ///      was chopped, possibly past the "[" itself). The owning device re-creates
    ///      a valid folder on its next mirror-up (now NFD-byte-budgeted, so it fits).
    ///   2. iCloud conflict duplicates inside an episode folder (e.g.
    ///      "transcript 2.txt") — anything that isn't one of the canonical
    ///      `cloudFile` names. Content is write-once, so the extras are redundant.
    private func cleanupContainerLocked() {
        guard let root = cloudRootLocked() else { return }
        let canonical = Set(Kind.allCases.map(\.cloudFile))
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            let isDir = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if parsedId(fromFolderName: folder.lastPathComponent) == nil {
                coordinatedRemove(folder)
                continue
            }
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if !canonical.contains(file.lastPathComponent) {
                    coordinatedRemove(file)
                }
            }
        }
    }

    private func coordinatedRemove(_ target: URL) {
        let coordinator = NSFileCoordinator()
        var err: NSError?
        coordinator.coordinate(writingItemAt: target, options: .forDeleting, error: &err) { url in
            try? fm.removeItem(at: url)
        }
    }

    /// A path component maxes out at 255 *bytes*; stay safely under it (iCloud may
    /// also append a " 2" conflict suffix). CJK is 3 bytes/char and emoji 4, so a
    /// character cap is not enough.
    private static let maxFolderNameBytes = 250

    private func folderName(displayName: String?, id: String) -> String {
        guard let name = displayName.map(sanitize), !name.isEmpty else { return id }
        // The "[id]" suffix is the round-trip key (see `parsedId`) and must
        // survive intact, so reserve its bytes first and fit as much of the
        // readable name as the remaining budget allows. Without this, a long CJK
        // title pushes the whole component past 255 bytes and the filesystem
        // chops off the "]" (or the id itself) — which silently breaks sync,
        // since the pull side can no longer map the folder back to its episode.
        let suffix = " [\(id)]"
        let budget = Self.maxFolderNameBytes - suffix.utf8.count
        let trimmed = byteLimited(name, maxBytes: budget).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? id : trimmed + suffix
    }

    /// Strip characters that break filenames or the `[id]` parsing and collapse
    /// whitespace. Length is bounded later by `folderName` (by bytes, around the
    /// id), so no character cap here.
    private func sanitize(_ s: String) -> String {
        var out = s
        for bad in ["/", "\\", ":", "[", "]", "\n", "\r", "\t"] {
            out = out.replacingOccurrences(of: bad, with: " ")
        }
        return out.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The longest prefix of `s` that fits in `maxBytes` UTF-8 bytes without
    /// splitting a character — measured in the *decomposed* (NFD) form, because
    /// the filesystem/iCloud store names decomposed: a Hangul syllable becomes 2-3
    /// jamo (~3x the bytes), so budgeting by the in-memory NFC bytes under-counts
    /// and the stored name still overruns the 255-byte limit and gets truncated.
    private func byteLimited(_ s: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        func nfdBytes(_ str: String) -> Int { str.decomposedStringWithCanonicalMapping.utf8.count }
        guard nfdBytes(s) > maxBytes else { return s }
        var out = ""
        for ch in s {
            if nfdBytes(out + String(ch)) > maxBytes { break }
            out.append(ch)
        }
        return out
    }

    /// The episode id a folder maps to, or nil if its name can't be mapped:
    /// a "<readable> [<id>]" folder must end with "]"; a bare-id folder is ASCII
    /// letters/digits/hyphens only (a UUID or "pod-<hex>"). A name truncated by the
    /// byte limit satisfies neither — it has Korean/spaces and no closing "]" — so
    /// it returns nil and is skipped on pull and removed by cleanup, instead of
    /// being mapped to a junk id.
    private func parsedId(fromFolderName name: String) -> String? {
        if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
            let start = name.index(after: open)
            let end = name.index(before: name.endIndex)
            if start < end { return String(name[start..<end]) }
            return nil
        }
        if AIContentKind.isValidEpisodeId(name) {
            return name
        }
        return nil
    }

    // MARK: - Incoming (iCloud -> local), via NSMetadataQuery on the main thread

    private func startQuery() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K IN %@",
                                  NSMetadataItemFSNameKey, Kind.allCases.map(\.cloudFile))
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated),
                                               name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated),
                                               name: .NSMetadataQueryDidUpdate, object: q)
        query = q
        q.start()
    }

    /// Runs on the main thread (the query's thread), so `NSMetadataItem`s never
    /// cross threads — only plain URLs/ids are handed off to `queue` for the copy.
    @objc private func queryUpdated() {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        var toPull: [(remote: URL, kind: Kind, id: String)] = []
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let remote = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let parsed = parseCloudURL(remote) else { continue }

            // Don't fight a copy we already have; the content is write-once.
            if fm.fileExists(atPath: localFile(parsed.kind, parsed.id).path) { continue }

            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
                toPull.append((remote, parsed.kind, parsed.id))
            } else {
                // Not materialized yet: request it; a DidUpdate fires when ready.
                try? fm.startDownloadingUbiquitousItem(at: remote)
            }
        }
        guard !toPull.isEmpty else { return }
        queue.async { self.pullLocked(toPull) }
    }

    private func pullLocked(_ entries: [(remote: URL, kind: Kind, id: String)]) {
        var pulledAny = false
        for entry in entries {
            let local = localFile(entry.kind, entry.id)
            guard !fm.fileExists(atPath: local.path) else { continue }
            try? fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let coordinator = NSFileCoordinator()
            var err: NSError?
            coordinator.coordinate(readingItemAt: entry.remote, options: [], error: &err) { url in
                guard !fm.fileExists(atPath: local.path) else { return }
                do { try fm.copyItem(at: url, to: local); pulledAny = true } catch {}
            }
        }
        if pulledAny {
            DispatchQueue.main.async { self.onDidPull?() }
        }
    }

    /// Map ".../Documents/<folder>/transcript.txt" to its (kind, episode id).
    private func parseCloudURL(_ url: URL) -> (kind: Kind, id: String)? {
        let comps = url.pathComponents
        guard let d = comps.firstIndex(of: "Documents"), comps.count == d + 3,
              let kind = Kind.allCases.first(where: { $0.cloudFile == comps[d + 2] }) else { return nil }
        // A folder whose name was truncated by the byte limit can't be mapped back
        // to its episode; skip it instead of pulling it to a junk-id local file.
        // The owning device re-creates a valid folder.
        guard let id = parsedId(fromFolderName: comps[d + 1]) else { return nil }
        return (kind, id)
    }
}
