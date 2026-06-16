import Combine
import Foundation

/// Subscribed podcast shows, persisted as plain JSON in Documents
/// (`podcasts.json`) — matching the app's no-database convention. Each feed
/// already carries its episodes as `EpisodeRecord`s, so the rest of the app
/// (player, downloads, favorites, AI) needs no podcast-specific code.
@MainActor
final class PodcastStore: ObservableObject {
    static let shared = PodcastStore()

    @Published private(set) var feeds: [PodcastFeed] = []

    private let storeURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = docs.appendingPathComponent("podcasts.json")
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([PodcastFeed].self, from: data) {
            feeds = saved
        }
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
        return feed
    }

    /// Subscribe to an already-parsed feed (no network) — re-subscribing from the
    /// detail view's heart toggle.
    func subscribe(_ feed: PodcastFeed) { upsert(feed) }

    func unsubscribe(id: String) {
        feeds.removeAll { $0.id == id }
        persist()
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
}
