import Combine
import CryptoKit
import Foundation

/// Subscribed podcast shows, persisted as plain JSON in Documents
/// (`podcasts.json`) — matching the app's no-database convention. Each feed
/// already carries its episodes as `EpisodeRecord`s, so the rest of the app
/// (player, downloads, favorites, AI) needs no podcast-specific code.
///
/// When iCloud sync is on, only the *subscription list* — one feed URL per show —
/// is mirrored through `CloudKVStore`; each device fetches and parses the feed
/// itself, so the large per-episode data never travels through the ~1 MB KVS
/// budget and episode lists stay fresh per device.
@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()

    @Published private(set) var feeds: [PodcastFeed] = []

    private let storeURL: URL
    /// Last-writer-wins subscription ledger (feed id -> entry), persisted as
    /// `podcast-subs.json`. Only Google Drive sync uses it (the iCloud path tracks
    /// subscriptions through per-feed KVS keys instead); it lets an unsubscribe — and
    /// a later re-subscribe — propagate to the Android app, which a plain union-merge
    /// of the feed list can't express. Maintained even when Drive is off (a cheap
    /// extra file), so it's ready the moment sync is enabled.
    private let subsURL: URL
    private var ledger: [String: PodcastSubEntry] = [:]

    /// KVS key prefix for synced subscriptions (one small key per show).
    private static let kvsPrefix = "pod-feed-"
    /// Whether to write through to / adopt from iCloud KVS.
    private var syncing = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent("podcasts.json")
        subsURL = docs.appendingPathComponent("podcast-subs.json")
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            feeds = saved
        }
        ledger = Self.loadLedger(subsURL)
        if SettingsStore.syncToICloudEnabled { enableSync() }
    }

    func isSubscribed(id: String) -> Bool { feeds.contains { $0.id == id } }

    func feed(id: String) -> PodcastFeed? { feeds.first { $0.id == id } }

    /// Resolve a pasted URL (Apple Podcasts page, apple.co link, or raw RSS),
    /// fetch + parse the feed, and subscribe. Returns the stored feed.
    /// Re-adding an existing show just refreshes the stored copy.
    @discardableResult
    func add(from pastedURL: URL) async throws -> PodcastFeed {
        let feedURL = try await PodcastAPI.resolveFeedURL(from: pastedURL)
        let data = try await PodcastAPI.fetchFeedData(feedURL)
        let feed = try PodcastFeedParser.parse(data, feedURL: feedURL)
        upsert(feed)
        pushSubscription(feed.id)
        recordSub(feed.id, subscribed: true)
        return feed
    }

    /// Subscribe to an already-parsed feed (no network) — re-subscribing from the
    /// detail view's heart toggle.
    func subscribe(_ feed: PodcastFeed) {
        upsert(feed)
        pushSubscription(feed.id)
        recordSub(feed.id, subscribed: true)
    }

    func unsubscribe(id: String) {
        feeds.removeAll { $0.id == id }
        persist()
        if syncing { CloudKVStore.shared.remove(feedKey(id)) }
        recordSub(id, subscribed: false)
    }

    /// Re-fetch a subscribed feed (its id is already the resolved RSS URL) and
    /// replace the stored copy, surfacing any newly published episodes.
    func refresh(_ id: String) async throws {
        guard let url = URL(string: id) else { return }
        let data = try await PodcastAPI.fetchFeedData(url)
        let feed = try PodcastFeedParser.parse(data, feedURL: url)
        upsert(feed)
    }

    private func upsert(_ feed: PodcastFeed) {
        if let i = feeds.firstIndex(where: { $0.id == feed.id }) {
            feeds[i] = feed
        } else {
            feeds.append(feed)
        }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(feeds).write(to: storeURL)
    }

    // MARK: - Google Drive sync (subscription ledger + reload)

    /// Record a subscribe/unsubscribe in the LWW ledger and fire a Drive sync.
    private func recordSub(_ id: String, subscribed: Bool) {
        ledger[id] = PodcastSubEntry(subscribed: subscribed, ts: Self.nowMillis)
        saveLedger()
        DriveSync.requestSync()
    }

    /// Re-read `podcasts.json` (the merged subscribed-feed set) and the ledger after
    /// a Google Drive pull rewrote them.
    func reload() {
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            feeds = saved
        }
        ledger = Self.loadLedger(subsURL)
    }

    private func saveLedger() {
        try? JSONEncoder().encode(ledger).write(to: subsURL)
    }

    private static func loadLedger(_ url: URL) -> [String: PodcastSubEntry] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: PodcastSubEntry].self, from: data) else { return [:] }
        return map
    }

    private static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - iCloud KVS sync (subscription list only)

    func enableSync() {
        guard !syncing else { return }
        syncing = true
        CloudKVStore.shared.observe(self, selector: #selector(feedsChangedInKVS))
        CloudKVStore.shared.synchronize()
        Task { await reconcile() }
    }

    func disableSync() {
        guard syncing else { return }
        syncing = false
        CloudKVStore.shared.unobserve(self)
    }

    private func pushSubscription(_ feedURL: String) {
        guard syncing else { return }
        CloudKVStore.shared.set(Data(feedURL.utf8), forKey: feedKey(feedURL))
    }

    @objc private func feedsChangedInKVS() {
        Task { @MainActor in await self.reconcile() }
    }

    /// Make the local subscription set match KVS: push anything local KVS is missing
    /// (subscribed while sync was off), drop shows unsubscribed on another device,
    /// and fetch + parse shows newly subscribed elsewhere. A feed that fails to
    /// download is left for a later pass — its KVS key stays, so it isn't lost.
    private func reconcile() async {
        guard syncing else { return }
        for feed in feeds where CloudKVStore.shared.data(forKey: feedKey(feed.id)) == nil {
            CloudKVStore.shared.setDeferred(Data(feed.id.utf8), forKey: feedKey(feed.id))
        }
        CloudKVStore.shared.synchronize()
        let remoteURLs = Set(CloudKVStore.shared.entries(prefix: Self.kvsPrefix)
            .compactMap { String(data: $0.data, encoding: .utf8) })

        // Drop shows unsubscribed elsewhere (every local show is now in KVS from
        // the push above, so this only removes genuine remote unsubscribes).
        if feeds.contains(where: { !remoteURLs.contains($0.id) }) {
            feeds.removeAll { !remoteURLs.contains($0.id) }
            persist()
        }

        // Materialize shows subscribed on another device.
        let haveURLs = Set(feeds.map(\.id))
        for url in remoteURLs where !haveURLs.contains(url) {
            guard let u = URL(string: url),
                  let data = try? await PodcastAPI.fetchFeedData(u),
                  let feed = try? PodcastFeedParser.parse(data, feedURL: u) else { continue }
            // Re-check after the await: still subscribed, still missing locally.
            guard syncing, CloudKVStore.shared.data(forKey: feedKey(url)) != nil,
                  !feeds.contains(where: { $0.id == feed.id }) else { continue }
            upsert(feed)
        }
    }

    /// Stable KVS key for a feed: a hash of its URL, so keys stay short and free of
    /// characters that might trip up the store.
    private func feedKey(_ feedURL: String) -> String {
        let digest = SHA256.hash(data: Data(feedURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.kvsPrefix + digest
    }
}
