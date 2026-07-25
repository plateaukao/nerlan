import Foundation

/// Where the listener stopped in each episode, so reopening one picks up instead
/// of restarting from zero. Plain JSON in Documents (`playback-positions.json`),
/// matching the rest of the app's no-database persistence.
///
/// Deliberately *not* synced. A resume offset is a per-device, per-moment thing
/// that goes stale the instant you press play somewhere else, so mirroring it
/// through the shared KVS budget would buy nothing.
final class PlaybackPositionStore {
    static let shared = PlaybackPositionStore()

    private struct Entry: Codable {
        var position: Double
        var duration: Double
        var updatedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL

    /// An episode under this many seconds in hasn't really been started, and one
    /// within this of the end has effectively finished — neither is worth
    /// resuming, and remembering them would make "play" replay the last breath
    /// of a lesson.
    private static let edgeSeconds: Double = 15
    /// Keeps the file small; the oldest entries fall off first.
    private static let maxEntries = 500

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("playback-positions.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// Seconds to resume `episodeId` at, or nil when there's nothing worth
    /// resuming.
    func position(for episodeId: String) -> Double? {
        guard let entry = entries[episodeId], entry.position > Self.edgeSeconds else { return nil }
        return entry.position
    }

    /// 0…1 through the episode, for the widgets' resume bars.
    func progress(for episodeId: String) -> Double? {
        guard let entry = entries[episodeId], entry.duration > 0 else { return nil }
        return min(1, max(0, entry.position / entry.duration))
    }

    /// Remember where playback is. A position at either edge clears the entry
    /// rather than storing a useless one.
    func record(episodeId: String, position: Double, duration: Double) {
        guard position.isFinite, position > 0 else { return }
        let nearEnd = duration > 0 && position >= duration - Self.edgeSeconds
        guard position > Self.edgeSeconds, !nearEnd else {
            clear(episodeId: episodeId)
            return
        }
        entries[episodeId] = Entry(position: position, duration: duration, updatedAt: Date())
        prune()
        persist()
    }

    /// Forget an episode — it finished, or was deleted.
    func clear(episodeId: String) {
        guard entries.removeValue(forKey: episodeId) != nil else { return }
        persist()
    }

    private func prune() {
        guard entries.count > Self.maxEntries else { return }
        let doomed = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }
            .prefix(entries.count - Self.maxEntries)
        for (key, _) in doomed { entries.removeValue(forKey: key) }
    }

    private func persist() {
        try? JSONEncoder().encode(entries).write(to: fileURL)
    }
}
