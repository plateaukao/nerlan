import Combine
import UIKit
import WidgetKit

/// Publishes everything the widgets draw into the shared App Group container.
///
/// The widget extension is a separate process with no access to Documents, the
/// player, or the network — so the app flattens its state into one small JSON
/// file (`WidgetSnapshot`) plus a folder of cover thumbnails, and pokes
/// WidgetKit. Writes are change-gated on a *signature* that deliberately omits
/// the playback position: while audio is playing the widget extrapolates the
/// position from `positionAt` and `rate` in its own timeline, so a moving
/// progress bar costs zero reloads. Only real changes — a different episode,
/// play/pause, a new favorite or download, another 5 minutes of listening —
/// spend from WidgetKit's reload budget.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    private var cancellables = Set<AnyCancellable>()
    /// Signature of the last snapshot written, to suppress no-op reloads.
    private var lastSignature: String?
    private var exportTask: Task<Void, Never>?

    private init() {}

    /// Start mirroring app state. Called once, from the app delegate.
    func start() {
        // Library + player changes: coalesce a burst (e.g. a queue swap emits
        // several) into one write.
        Publishers.MergeMany([
            PlayerManager.shared.objectWillChange,
            FavoritesStore.shared.objectWillChange,
            DownloadManager.shared.objectWillChange,
            PodcastStore.shared.objectWillChange,
        ])
        .debounce(for: .seconds(1), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.refresh() }
        .store(in: &cancellables)

        // Listening stats tick twice a second during playback; the snapshot only
        // carries whole minutes, so sampling once a minute is plenty.
        ListeningStatsStore.shared.objectWillChange
            .throttle(for: .seconds(60), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Leaving the app is the one moment worth writing unconditionally: it
        // pins an accurate playback position for the widget to extrapolate from.
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refresh(force: true) }
                .store(in: &cancellables)
        }

        refresh(force: true)
        Task { await refreshLatestEpisodes() }
    }

    /// Rebuild and publish the snapshot. `force` skips the change check (used on
    /// launch and when backgrounding).
    func refresh(force: Bool = false) {
        var covers: [String: String] = [:]
        let snapshot = buildSnapshot(covers: &covers)
        let signature = Self.signature(of: snapshot)
        guard force || signature != lastSignature else { return }
        lastSignature = signature
        guard WidgetShare.writeSnapshot(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        exportCovers(covers)
    }

    // MARK: - Snapshot

    private func buildSnapshot(covers: inout [String: String]) -> WidgetSnapshot {
        let player = PlayerManager.shared
        let nowPlaying = player.current.map { episode($0, covers: &covers) }

        return WidgetSnapshot(
            updatedAt: Date(),
            nowPlaying: nowPlaying,
            isPlaying: player.isPlaying,
            position: player.clock.currentTime,
            positionAt: Date(),
            rate: Double(player.playbackRate),
            upNext: upNext(covers: &covers),
            shows: shows(covers: &covers),
            stats: stats())
    }

    /// What follows the current episode: the rest of the player queue first,
    /// topped up with recent downloads and favorites so the widget still has
    /// something to offer before anything has been played.
    private func upNext(covers: inout [String: String]) -> [WidgetEpisode] {
        let player = PlayerManager.shared
        var records: [EpisodeRecord] = []
        if let current = player.current, let index = player.queue.firstIndex(of: current) {
            records = Array(player.queue[(index + 1)...])
        }
        // Newest first: both stores append as the user adds.
        records += DownloadManager.shared.records.reversed()
        records += FavoritesStore.shared.favorites.reversed()

        var seen = Set([player.current?.id].compactMap { $0 })
        var out: [WidgetEpisode] = []
        for record in records where !seen.contains(record.id) {
            seen.insert(record.id)
            out.append(episode(record, covers: &covers))
            if out.count == 8 { break }
        }
        return out
    }

    /// Favorited NER programs and subscribed podcasts, each with its newest
    /// episodes so 最新單集 can render without another lookup.
    private func shows(covers: inout [String: String]) -> [WidgetShow] {
        var out: [WidgetShow] = []

        for program in FavoritesStore.shared.programs {
            var key: String?
            if let cover = program.coverURL?.absoluteString, let k = WidgetShare.coverKey(for: cover) {
                key = k
                covers[k] = cover
            }
            let latest = WidgetLatestEpisodes.latest(programId: program.programId)
                .prefix(3)
                .map { episode($0, covers: &covers) }
            out.append(WidgetShow(id: program.programId, name: program.name,
                                  language: program.language, coverKey: key,
                                  isPodcast: false, latest: Array(latest)))
        }

        for feed in PodcastStore.shared.feeds {
            var key: String?
            if let cover = feed.coverURL, let k = WidgetShare.coverKey(for: cover) {
                key = k
                covers[k] = cover
            }
            // Feed order isn't guaranteed newest-first; sort explicitly.
            let latest = feed.episodes
                .sorted { ($0.playDate ?? "") > ($1.playDate ?? "") }
                .prefix(3)
                .map { episode($0, covers: &covers) }
            out.append(WidgetShow(id: feed.id, name: feed.title, language: feed.language,
                                  coverKey: key, isPodcast: true, latest: Array(latest)))
        }

        return Array(out.prefix(12))
    }

    private func stats() -> WidgetStats {
        let store = ListeningStatsStore.shared
        return WidgetStats(minutesToday: Int(store.secondsToday / 60),
                           minutesThisWeek: Int(store.secondsThisWeek / 60),
                           streakDays: store.currentStreak,
                           completedCount: store.completedCount)
    }

    private func episode(_ record: EpisodeRecord, covers: inout [String: String]) -> WidgetEpisode {
        var key: String?
        if let cover = record.coverURL, let k = WidgetShare.coverKey(for: cover) {
            key = k
            covers[k] = cover
        }
        return WidgetEpisode(id: record.id,
                             title: record.title,
                             programId: record.programId,
                             programName: record.programName,
                             language: record.language,
                             duration: record.durationSeconds.map(Double.init),
                             coverKey: key,
                             isDownloaded: DownloadManager.shared.isDownloaded(episodeId: record.id),
                             // Only podcast records carry an audio locale.
                             isPodcast: record.audioLocale != nil)
    }

    /// Everything worth spending a widget reload on. Deliberately excludes the
    /// playback position (the widget extrapolates it) and rounds listening
    /// minutes to 5, so a listening session doesn't reload once a minute.
    private static func signature(of snapshot: WidgetSnapshot) -> String {
        var parts: [String] = [
            snapshot.nowPlaying?.id ?? "-",
            snapshot.isPlaying ? "1" : "0",
            snapshot.upNext.map(\.id).joined(separator: ","),
            snapshot.shows.map { "\($0.id):\($0.latest.map(\.id).joined(separator: "+"))" }
                .joined(separator: ","),
        ]
        parts.append("\(snapshot.stats.minutesToday / 5)|\(snapshot.stats.streakDays)|\(snapshot.stats.completedCount)")
        return parts.joined(separator: "#")
    }

    // MARK: - Cover thumbnails

    /// Mirror each referenced cover into the group container as a small JPEG.
    /// The widget process can't reach the app's Caches folder, and re-downloading
    /// from an extension would be both slow and budget-hostile.
    private func exportCovers(_ covers: [String: String]) {
        guard let dir = WidgetShare.coversDir else { return }
        exportTask?.cancel()
        exportTask = Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var wroteAny = false
            for (key, urlString) in covers {
                if Task.isCancelled { return }
                let dest = dir.appendingPathComponent(key)
                guard !FileManager.default.fileExists(atPath: dest.path),
                      let url = URL(string: urlString),
                      let image = await CoverImageCache.shared.image(for: url),
                      let data = Self.thumbnailJPEG(image) else { continue }
                try? data.write(to: dest, options: .atomic)
                wroteAny = true
            }
            // Drop covers no longer referenced, so the container doesn't grow.
            let keep = Set(covers.keys)
            let existing = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in existing where !keep.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
            if wroteAny { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    /// Widgets render covers at most ~100pt, so 300px is generous; keeping them
    /// small matters because a widget process is capped at ~30 MB. Runs off the
    /// main actor (from `exportCovers`' detached task) — `UIGraphicsImageRenderer`
    /// is safe on any thread.
    nonisolated private static func thumbnailJPEG(_ image: UIImage, maxPixel: CGFloat = 300) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, maxPixel / max(pixelWidth, pixelHeight))
        let size = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }

    // MARK: - Latest episodes

    /// Refresh the "newest episode" of each favorited NER program. Podcasts need
    /// no fetch (their feed is already local) and the catalog cache can't answer
    /// this — it holds pages ascending from episode 1, so its tail is wherever
    /// the user last scrolled to, not the newest episode.
    func refreshLatestEpisodes() async {
        let programs = FavoritesStore.shared.programs
        guard await WidgetLatestEpisodes.refresh(programs: programs) else { return }
        refresh(force: true)
    }
}

/// Newest-episode-per-program cache backing the 最新單集 widget. Lives in Caches
/// (derived, re-fetchable) and is refreshed at most every 6 hours — NER courses
/// gain an episode a day at most, so anything tighter is pure network chatter.
enum WidgetLatestEpisodes {
    private struct Entry: Codable {
        var fetchedAt: Date
        var episodes: [EpisodeRecord]
    }

    private static let refreshInterval: TimeInterval = 6 * 3600

    private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("widget-latest.json")
    }()

    private static var cache: [String: Entry] = load()

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// Newest first; empty until the first successful fetch.
    static func latest(programId: String) -> [EpisodeRecord] {
        cache[programId]?.episodes ?? []
    }

    /// Fetch anything stale. Returns whether the cache actually changed.
    @discardableResult
    static func refresh(programs: [Program]) async -> Bool {
        let now = Date()
        var changed = false
        for program in programs {
            if let entry = cache[program.programId],
               now.timeIntervalSince(entry.fetchedAt) < refreshInterval { continue }
            guard let episodes = try? await ChannelPlusAPI.latestEpisodes(programId: program.programId)
            else { continue }
            let records = episodes.map {
                EpisodeRecord(episode: $0, programId: program.programId,
                              programName: program.name, language: program.language,
                              coverURL: program.coverURL?.absoluteString)
            }
            if cache[program.programId]?.episodes != records { changed = true }
            cache[program.programId] = Entry(fetchedAt: now, episodes: records)
        }
        // Forget programs that are no longer favorited.
        let live = Set(programs.map(\.programId))
        let stale = cache.keys.filter { !live.contains($0) }
        if !stale.isEmpty {
            for key in stale { cache.removeValue(forKey: key) }
            changed = true
        }
        if changed { try? JSONEncoder().encode(cache).write(to: fileURL) }
        return changed
    }
}
