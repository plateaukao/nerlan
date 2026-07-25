import Combine
import Foundation

/// The shows you've actually been listening to, newest first — one entry per
/// program or podcast, remembering which episode it left off on.
///
/// Kept separate from `FavoritesStore.programs` on purpose: you can work through
/// a course for weeks without ever tapping its heart, and the useful widget is
/// "put me back where I was", not "shows I bookmarked". Persisted as
/// `recent-shows.json` in Documents, like every other store here.
final class RecentShowsStore: ObservableObject {
    static let shared = RecentShowsStore()

    struct Entry: Codable, Identifiable, Hashable {
        var id: String            // programId, or the feed URL for a podcast
        var name: String
        var language: String
        var coverURL: String?
        var isPodcast: Bool
        var lastEpisodeId: String
        var lastEpisodeTitle: String
        var playedAt: Date
    }

    /// Newest first.
    @Published private(set) var shows: [Entry] = []

    /// Enough to fill the largest widget several times over; beyond that it's
    /// history, not "recent".
    private static let limit = 12

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("recent-shows.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            shows = saved
        }
    }

    /// Called from `PlayerManager.load` — the single chokepoint every playback
    /// path goes through, so nothing can start playing without being recorded.
    func note(_ record: EpisodeRecord) {
        let entry = Entry(id: record.programId,
                          name: record.programName,
                          language: record.language,
                          coverURL: record.coverURL,
                          // Only podcast records carry an audio locale.
                          isPodcast: record.audioLocale != nil,
                          lastEpisodeId: record.id,
                          lastEpisodeTitle: record.title,
                          playedAt: Date())
        shows.removeAll { $0.id == entry.id }
        shows.insert(entry, at: 0)
        if shows.count > Self.limit { shows.removeLast(shows.count - Self.limit) }
        persist()
    }

    func entry(id: String) -> Entry? { shows.first { $0.id == id } }

    private func persist() {
        try? JSONEncoder().encode(shows).write(to: fileURL)
    }
}
