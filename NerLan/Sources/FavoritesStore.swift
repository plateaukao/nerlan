import Combine
import Foundation

/// Favorited episodes and programs, persisted as JSON in Documents. When iCloud
/// sync is on, each favorite is also mirrored to `CloudKVStore` under its own key
/// so favorites follow the user across devices and survive reinstalls.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var favorites: [EpisodeRecord] = []
    @Published private(set) var programs: [Program] = []

    private let episodesURL: URL
    private let programsURL: URL

    private static let epPrefix = "fav-ep-"
    private static let progPrefix = "fav-prog-"
    /// Whether to write through to / adopt from iCloud KVS.
    private var syncing = false

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
        if SettingsStore.syncToICloudEnabled { enableSync() }
    }

    private func epKey(_ id: String) -> String { Self.epPrefix + id }
    private func progKey(_ id: String) -> String { Self.progPrefix + id }

    // MARK: - Episodes

    func isFavorite(episodeId: String) -> Bool {
        favorites.contains { $0.id == episodeId }
    }

    func toggle(_ record: EpisodeRecord) {
        if isFavorite(episodeId: record.id) {
            favorites.removeAll { $0.id == record.id }
            if syncing { CloudKVStore.shared.remove(epKey(record.id)) }
        } else {
            favorites.append(record)
            if syncing, let data = try? JSONEncoder().encode(record) {
                CloudKVStore.shared.set(data, forKey: epKey(record.id))
            }
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
            if syncing { CloudKVStore.shared.remove(progKey(program.programId)) }
        } else {
            programs.append(program)
            if syncing, let data = try? JSONEncoder().encode(program) {
                CloudKVStore.shared.set(data, forKey: progKey(program.programId))
            }
        }
        try? JSONEncoder().encode(programs).write(to: programsURL)
    }

    // MARK: - iCloud KVS sync

    func enableSync() {
        guard !syncing else { return }
        syncing = true
        CloudKVStore.shared.observe(self, selector: #selector(kvsChanged))
        reconcile()
        CloudKVStore.shared.synchronize()
    }

    func disableSync() {
        guard syncing else { return }
        syncing = false
        CloudKVStore.shared.unobserve(self)
    }

    /// Bring this device into sync: push anything local that KVS is missing
    /// (e.g. favorited while sync was off), then adopt the merged set.
    private func reconcile() {
        for record in favorites where CloudKVStore.shared.data(forKey: epKey(record.id)) == nil {
            if let data = try? JSONEncoder().encode(record) {
                CloudKVStore.shared.set(data, forKey: epKey(record.id))
            }
        }
        for program in programs where CloudKVStore.shared.data(forKey: progKey(program.programId)) == nil {
            if let data = try? JSONEncoder().encode(program) {
                CloudKVStore.shared.set(data, forKey: progKey(program.programId))
            }
        }
        adoptFromKVS()
    }

    @objc private func kvsChanged() {
        DispatchQueue.main.async { [weak self] in self?.adoptFromKVS() }
    }

    /// KVS is authoritative for favorites (they have no file backing), so a
    /// remote add or remove replaces the local set — letting unfavoriting on one
    /// device propagate to the others.
    private func adoptFromKVS() {
        let eps = CloudKVStore.shared.entries(prefix: Self.epPrefix)
            .compactMap { try? JSONDecoder().decode(EpisodeRecord.self, from: $0.data) }
        let progs = CloudKVStore.shared.entries(prefix: Self.progPrefix)
            .compactMap { try? JSONDecoder().decode(Program.self, from: $0.data) }
        favorites = eps
        programs = progs
        try? JSONEncoder().encode(favorites).write(to: episodesURL)
        try? JSONEncoder().encode(programs).write(to: programsURL)
    }
}
