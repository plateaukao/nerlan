import Combine
import Foundation

/// Favorited episodes and programs, persisted as JSON in Documents.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [EpisodeRecord] = []
    @Published private(set) var programs: [Program] = []

    private let episodesURL: URL
    private let programsURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        episodesURL = docs.appendingPathComponent("favorites.json")
        programsURL = docs.appendingPathComponent("favorite-programs.json")
        if let data = try? Data(contentsOf: episodesURL),
           let saved = try? JSONDecoder().decode([EpisodeRecord].self, from: data) {
            favorites = saved
        }
        if let data = try? Data(contentsOf: programsURL),
           let saved = try? JSONDecoder().decode([Program].self, from: data) {
            programs = saved
        }
    }

    // MARK: - Episodes

    func isFavorite(episodeId: String) -> Bool {
        favorites.contains { $0.id == episodeId }
    }

    func toggle(_ record: EpisodeRecord) {
        if isFavorite(episodeId: record.id) {
            favorites.removeAll { $0.id == record.id }
        } else {
            favorites.append(record)
        }
        try? JSONEncoder().encode(favorites).write(to: episodesURL)
    }

    // MARK: - Programs

    func isFavorite(programId: String) -> Bool {
        programs.contains { $0.programId == programId }
    }

    func toggle(program: Program) {
        if isFavorite(programId: program.programId) {
            programs.removeAll { $0.programId == program.programId }
        } else {
            programs.append(program)
        }
        try? JSONEncoder().encode(programs).write(to: programsURL)
    }
}
