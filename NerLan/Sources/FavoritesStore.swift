import Combine
import Foundation

/// Favorited episodes, persisted as JSON in Documents.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [EpisodeRecord] = []

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("favorites.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([EpisodeRecord].self, from: data) {
            favorites = saved
        }
    }

    func isFavorite(episodeId: String) -> Bool {
        favorites.contains { $0.id == episodeId }
    }

    func toggle(_ record: EpisodeRecord) {
        if isFavorite(episodeId: record.id) {
            favorites.removeAll { $0.id == record.id }
        } else {
            favorites.append(record)
        }
        try? JSONEncoder().encode(favorites).write(to: fileURL)
    }
}
