import Combine
import UIKit
import WidgetKit

/// Publishes everything the widgets draw into the shared App Group container.
///
/// The widget extension is a separate process with no access to Documents, the
/// player, or the network — so the app flattens its state into one small JSON
/// file (`WidgetSnapshot`) plus a folder of cover thumbnails, and pokes
/// WidgetKit. Writing the file is free; the poke is not. WidgetKit budgets
/// roughly 40–70 reloads per widget per day, and exceeding it doesn't just
/// stale the widget — chronod flags the whole extension and starts *denying*
/// timeline fetches, so a widget whose archived render the system dropped
/// (reboot, respring, memory purge) redraws as a bare gray placeholder and
/// stays that way for hours. That was this app at ~250 reload calls a day.
///
/// So the two are decided separately. The snapshot file is written whenever
/// anything moved, keeping it accurate for the widgets' own scheduled refetches
/// (every 30 minutes while playing, hourly otherwise). A reload is spent only
/// on a *visible transition* — a different episode, play/pause, the queue or
/// library changing — never on the playback position (the widget extrapolates
/// it from `positionAt` and `rate` locally) and never on the 最近播放 resume
/// percentages (the scheduled refetches pick those up). Listening stats run on
/// their own coarser signature and reload only the stats widget kind.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    private var cancellables = Set<AnyCancellable>()
    /// Reload-worthy signature as of the last reload, so budget is spent only
    /// on transitions the user can see at a glance.
    private var lastReloadSignature: String?
    /// Ditto for the stats widget, which changes on its own coarser clock.
    private var lastStatsSignature: String?
    /// The snapshot most recently written, to detect seeks — position jumps the
    /// widget's local extrapolation can't follow.
    private var lastWritten: WidgetSnapshot?
    /// Seek-driven reloads are rate-limited: a learner replaying sentences taps
    /// ±15s in bursts, and a slightly-off progress bar is only cosmetic.
    private var lastSeekReload = Date.distantPast
    /// Last hourly foreground repaint — see `repairIfDue`.
    private var lastRepair = Date.distantPast
    private var exportTask: Task<Void, Never>?
    /// Cover set the export worker should drain next; replaced, not appended to,
    /// since each snapshot carries the complete set.
    private var pendingCovers: [String: String] = [:]

    private init() {}

    private var started = false

    /// Start mirroring app state. Idempotent, and called from both the app
    /// delegate and the root view's `.task` — the delegate is the earliest hook
    /// (it also has to be in place before a widget's playback intent can arrive),
    /// but the view callback is the one guaranteed to run.
    func start() {
        guard !started else { return }
        started = true
        // Library + player changes: coalesce a burst (e.g. a queue swap emits
        // several) into one write.
        Publishers.MergeMany([
            PlayerManager.shared.objectWillChange,
            FavoritesStore.shared.objectWillChange,
            DownloadManager.shared.objectWillChange,
            PodcastStore.shared.objectWillChange,
            RecentShowsStore.shared.objectWillChange,
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

        // Leaving the app pins an accurate playback position in the file for
        // the widget to extrapolate from. A write, not a reload: resign-active
        // fires for every lock, app switch, and Control Center pull, and the
        // unconditional reloads here were a large slice of the budget overrun.
        for name in [UIApplication.didEnterBackgroundNotification,
                     UIApplication.willResignActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.refresh(force: true) }
                .store(in: &cancellables)
        }

        // Coming back to the foreground, repaint everything once an hour even
        // if nothing changed: foreground reload requests are honored
        // immediately without touching the budget, so this un-sticks a widget
        // the system left as a gray placeholder while we were over budget.
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.repairIfDue() }
            .store(in: &cancellables)

        lastRepair = Date()  // the launch refresh below already reloads
        refresh(force: true)
        Task { await refreshLatestEpisodes() }
    }

    /// Rebuild the snapshot, write it if anything moved, and reload only what a
    /// visible transition justifies (see the class comment for why). `force`
    /// writes the file even when nothing changed — used on launch and when
    /// backgrounding — but never forces a reload by itself.
    func refresh(force: Bool = false) {
        var covers: [String: String] = [:]
        let snapshot = buildSnapshot(covers: &covers)

        let reloadSignature = Self.reloadSignature(of: snapshot)
        let statsSignature = Self.statsSignature(of: snapshot)
        let seeked = seekedSinceLastWrite(snapshot)
        let reloadAll = reloadSignature != lastReloadSignature || seeked
        let statsChanged = statsSignature != lastStatsSignature

        guard force || reloadAll || statsChanged else { return }
        guard WidgetShare.writeSnapshot(snapshot) else { return }
        lastWritten = snapshot

        if reloadAll {
            lastReloadSignature = reloadSignature
            lastStatsSignature = statsSignature
            if seeked { lastSeekReload = Date() }
            WidgetCenter.shared.reloadAllTimelines()
        } else if statsChanged {
            lastStatsSignature = statsSignature
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.stats)
        }
        exportCovers(covers)
    }

    /// Hourly full repaint when the app comes to the foreground — see start().
    private func repairIfDue() {
        guard Date().timeIntervalSince(lastRepair) > 3600 else { return }
        lastRepair = Date()
        lastReloadSignature = nil  // makes the refresh below reload everything
        refresh(force: true)
    }

    /// Whether playback jumped (a seek) relative to what the last written
    /// snapshot lets the widget extrapolate. Worth a reload — the progress bar
    /// is otherwise wrong until the next scheduled refetch — but only past a
    /// threshold a glance would notice, and rate-limited via `lastSeekReload`.
    private func seekedSinceLastWrite(_ snapshot: WidgetSnapshot) -> Bool {
        guard let last = lastWritten,
              let episode = snapshot.nowPlaying, last.nowPlaying?.id == episode.id,
              abs(last.position(at: snapshot.positionAt) - snapshot.position) > 30
        else { return false }
        return Date().timeIntervalSince(lastSeekReload) > 300
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
            recents: recents(covers: &covers),
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
    /// episodes so 最新單集 can render without another lookup. Ordered so the
    /// handful the 我的節目 grid can show are the useful ones — see the sort below.
    private func shows(covers: inout [String: String]) -> [WidgetShow] {
        var out: [WidgetShow] = []

        for program in FavoritesStore.shared.programs {
            let latest = WidgetLatestEpisodes.latest(programId: program.programId)
                .prefix(3)
                .map { episode($0, covers: &covers) }
            out.append(show(id: program.programId, name: program.name,
                            language: program.language,
                            coverURL: program.coverURL?.absoluteString,
                            isPodcast: false, latest: Array(latest), covers: &covers))
        }

        for feed in PodcastStore.shared.feeds {
            // Feed order isn't guaranteed newest-first; sort explicitly.
            let latest = feed.episodes
                .sorted { ($0.playDate ?? "") > ($1.playDate ?? "") }
                .prefix(3)
                .map { episode($0, covers: &covers) }
            out.append(show(id: feed.id, name: feed.title, language: feed.language,
                            coverURL: feed.coverURL, isPodcast: true,
                            latest: Array(latest), covers: &covers))
        }

        // Recently played first, then by listening time. Ranking on listening
        // time alone buried every podcast: favorited programs are more numerous
        // and carry almost all the accumulated time, so a 4-slot grid never
        // reached one. Pinning podcasts above programs (as the 節目 tab does)
        // only inverts that. Recency mixes the two kinds on the signal that
        // actually matters — what's being worked through right now — and the
        // widget's show picker overrides it for anything deliberate.
        // `uniquingKeysWith` keeps this total even if a duplicate id ever slipped
        // into the recents file — a trap here would take the whole app down.
        let recentRank = Dictionary(
            RecentShowsStore.shared.shows.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let seconds = ListeningStatsStore.shared.secondsByProgram()
        out.sort {
            switch (recentRank[$0.id], recentRank[$1.id]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let a = seconds[$0.id] ?? 0, b = seconds[$1.id] ?? 0
                // Never-played shows keep a stable order rather than shuffling.
                return a == b ? $0.name < $1.name : a > b
            }
        }

        // Cap each kind separately. This list also populates the widget's show
        // picker, so anything dropped here can't be chosen at all — and with ~19
        // podcasts subscribed, one shared cap would have squeezed the programs
        // out the moment podcasts moved up.
        var keep = Set(out.filter(\.isPodcast).prefix(20).map(\.id))
        keep.formUnion(out.filter { !$0.isPodcast }.prefix(20).map(\.id))
        return out.filter { keep.contains($0.id) }
    }

    /// Shows recently played, newest first — including ones that were never
    /// favorited, which is the common case for a course being worked through.
    private func recents(covers: inout [String: String]) -> [WidgetShow] {
        RecentShowsStore.shared.shows.prefix(8).map { entry in
            show(id: entry.id, name: entry.name, language: entry.language,
                 coverURL: entry.coverURL, isPodcast: entry.isPodcast,
                 latest: [], covers: &covers,
                 lastEpisodeId: entry.lastEpisodeId,
                 lastEpisodeTitle: entry.lastEpisodeTitle,
                 lastPlayedAt: entry.playedAt,
                 resumeProgress: PlaybackPositionStore.shared.progress(for: entry.lastEpisodeId))
        }
    }

    private func show(id: String, name: String, language: String, coverURL: String?,
                      isPodcast: Bool, latest: [WidgetEpisode], covers: inout [String: String],
                      lastEpisodeId: String? = nil, lastEpisodeTitle: String? = nil,
                      lastPlayedAt: Date? = nil, resumeProgress: Double? = nil) -> WidgetShow {
        var key: String?
        if let coverURL, let k = WidgetShare.coverKey(for: coverURL) {
            key = k
            covers[k] = coverURL
        }
        return WidgetShow(id: id, name: name, language: language, coverKey: key,
                          isPodcast: isPodcast, latest: latest,
                          lastEpisodeId: lastEpisodeId, lastEpisodeTitle: lastEpisodeTitle,
                          lastPlayedAt: lastPlayedAt, resumeProgress: resumeProgress)
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

    /// The transitions worth an immediate reload of every widget: a different
    /// episode, play/pause, a rate change (it steers the widget's local
    /// extrapolation), or the queue / library / recents changing what they
    /// list. Positions, resume percentages, and stats are deliberately absent —
    /// they reach the widgets through the file alone.
    private static func reloadSignature(of snapshot: WidgetSnapshot) -> String {
        [
            snapshot.nowPlaying?.id ?? "-",
            snapshot.isPlaying ? "1" : "0",
            String(snapshot.rate),
            snapshot.upNext.map(\.id).joined(separator: ","),
            snapshot.shows.map { "\($0.id):\($0.latest.map(\.id).joined(separator: "+"))" }
                .joined(separator: ","),
            snapshot.recentShows.map { "\($0.id):\($0.lastEpisodeId ?? "-")" }
                .joined(separator: ","),
        ].joined(separator: "#")
    }

    /// The stats widget's own clock: whole 15-minute steps of listening plus
    /// the streak and completed counters — at most a few reloads per listening
    /// hour, spent on that one widget kind only.
    private static func statsSignature(of snapshot: WidgetSnapshot) -> String {
        "\(snapshot.stats.minutesToday / 15)|\(snapshot.stats.minutesThisWeek / 15)"
            + "|\(snapshot.stats.streakDays)|\(snapshot.stats.completedCount)"
    }

    // MARK: - Cover thumbnails

    /// Mirror each referenced cover into the group container as a small JPEG.
    /// The widget process can't reach the app's Caches folder, and re-downloading
    /// from an extension would be both slow and budget-hostile.
    /// Export runs are *queued*, never cancelled. Cancelling on each refresh was
    /// the bug that left widgets with placeholder artwork: launch alone fires
    /// several refreshes seconds apart, so every export was killed mid-download
    /// and `covers/` stayed empty. Instead the newest request replaces the
    /// pending set and one worker drains it to completion.
    private func exportCovers(_ covers: [String: String]) {
        pendingCovers = covers
        guard exportTask == nil else { return }
        exportTask = Task { [weak self] in
            while let self, !self.pendingCovers.isEmpty {
                let batch = self.pendingCovers
                if await Self.export(batch) { WidgetCenter.shared.reloadAllTimelines() }
                // A refresh during the export may have queued a different set.
                if self.pendingCovers == batch { self.pendingCovers = [:] }
            }
            self?.exportTask = nil
        }
    }

    /// Fetch and downscale anything missing, then drop covers no longer
    /// referenced so the container doesn't grow. Returns whether anything new
    /// landed (i.e. whether a reload would show something different).
    nonisolated private static func export(_ covers: [String: String]) async -> Bool {
        guard let dir = WidgetShare.coversDir else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var wroteAny = false
        for (key, urlString) in covers {
            let dest = dir.appendingPathComponent(key)
            guard !FileManager.default.fileExists(atPath: dest.path),
                  let url = URL(string: urlString),
                  let image = await CoverImageCache.shared.image(for: url),
                  let data = thumbnailJPEG(image) else { continue }
            try? data.write(to: dest, options: .atomic)
            wroteAny = true
        }
        let keep = Set(covers.keys)
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in existing where !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        return wroteAny
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
