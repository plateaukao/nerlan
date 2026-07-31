import Combine
import Foundation

/// User-written notes on episodes, keyed by episode id. Course episodes are
/// often titled just "EP12", so a note is how the user records what's actually
/// inside; the episode lists show it under the title. Persisted as JSON in
/// Documents (`episode-notes.json`); when iCloud sync is on, each note is also
/// mirrored to `CloudKVStore` under its own key (like favorites) so notes
/// survive reinstalls and follow the user across devices.
final class EpisodeNotesStore: ObservableObject {
    static let shared = EpisodeNotesStore()

    @Published private(set) var notes: [String: String] = [:]

    private let fileURL: URL
    private static let keyPrefix = "note-ep-"
    /// Whether to write through to / adopt from iCloud KVS.
    private var syncing = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("episode-notes.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            notes = saved
        }
        if SettingsStore.syncToICloudEnabled { enableSync() }
    }

    private func key(_ id: String) -> String { Self.keyPrefix + id }

    func note(for episodeId: String) -> String? {
        notes[episodeId]
    }

    /// Save (or clear, when the trimmed text is empty) the note for an episode.
    func setNote(_ text: String, for episodeId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard notes.removeValue(forKey: episodeId) != nil else { return }
            if syncing { CloudKVStore.shared.remove(key(episodeId)) }
        } else {
            guard notes[episodeId] != trimmed else { return }
            notes[episodeId] = trimmed
            if syncing { CloudKVStore.shared.set(Data(trimmed.utf8), forKey: key(episodeId)) }
        }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(notes).write(to: fileURL)
    }

    // MARK: - iCloud KVS sync

    func enableSync() {
        guard !syncing else { return }
        syncing = true
        CloudKVStore.shared.observe(self, selector: #selector(kvsChanged(_:)))
        reconcile()
    }

    func disableSync() {
        guard syncing else { return }
        syncing = false
        CloudKVStore.shared.unobserve(self)
    }

    /// Bring this device into sync: push anything local that KVS is missing
    /// (e.g. written while sync was off), then adopt the merged set.
    private func reconcile() {
        for (id, text) in notes where CloudKVStore.shared.data(forKey: key(id)) == nil {
            CloudKVStore.shared.setDeferred(Data(text.utf8), forKey: key(id))
        }
        CloudKVStore.shared.synchronize()
        adoptFromKVS()
    }

    @objc private func kvsChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            ?? NSUbiquitousKeyValueStoreServerChange
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch reason {
            case NSUbiquitousKeyValueStoreAccountChange, NSUbiquitousKeyValueStoreInitialSyncChange:
                // The system replaced the store's contents — possibly with an
                // empty set. Adopting that blindly would wipe every local note,
                // so re-push local ones first and adopt the union instead.
                self.reconcile()
            default:
                self.adoptFromKVS()
            }
        }
    }

    /// KVS is authoritative for notes (mirroring favorites), so a remote edit or
    /// removal replaces the local set — letting a note cleared on one device
    /// disappear from the others.
    private func adoptFromKVS() {
        var adopted: [String: String] = [:]
        for (key, data) in CloudKVStore.shared.entries(prefix: Self.keyPrefix) {
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            adopted[String(key.dropFirst(Self.keyPrefix.count))] = text
        }
        notes = adopted
        persist()
    }
}
