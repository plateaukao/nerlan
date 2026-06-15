import Foundation

/// On-disk cache of the Channel+ catalog — the program list and each program's
/// loaded episode pages — so the browse UI renders instantly (even offline) and
/// only hits the network on a cache miss or an explicit pull-to-refresh. The
/// catalog rarely changes (sequential language courses gain episodes only at the
/// end), so cached data is treated as authoritative until the user refreshes.
///
/// Files live in Caches, not Documents: this is derived, re-fetchable data, so it
/// stays out of iCloud backups and the OS may purge it under storage pressure
/// (the next launch simply re-fetches). User data — favorites, downloads — stays
/// in Documents as before.
enum CatalogCache {
    private static let dir: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Program list

    private static var programsURL: URL { dir.appendingPathComponent("programs.json") }

    static func loadPrograms() -> [Program]? {
        guard let data = try? Data(contentsOf: programsURL) else { return nil }
        return try? JSONDecoder().decode([Program].self, from: data)
    }

    static func savePrograms(_ programs: [Program]) {
        try? JSONEncoder().encode(programs).write(to: programsURL)
    }

    // MARK: - Episode pages

    /// The episodes loaded so far for one program plus its pagination cursor, so a
    /// reopen restores the list and infinite scroll resumes from where it left off
    /// instead of re-fetching the pages already seen.
    struct EpisodePage: Codable {
        var episodes: [Episode]
        var page: Int
        var totalPages: Int
        var totalCount: Int
    }

    private static func episodesURL(_ programId: String) -> URL {
        dir.appendingPathComponent("episodes-\(programId).json")
    }

    static func loadEpisodes(programId: String) -> EpisodePage? {
        guard let data = try? Data(contentsOf: episodesURL(programId)) else { return nil }
        return try? JSONDecoder().decode(EpisodePage.self, from: data)
    }

    static func saveEpisodes(_ page: EpisodePage, programId: String) {
        try? JSONEncoder().encode(page).write(to: episodesURL(programId))
    }
}
