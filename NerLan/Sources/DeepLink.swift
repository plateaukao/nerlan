import Combine
import Foundation

/// Routes `nerlan://` URLs (opened by the widgets) to the right place in the UI.
///
/// The app has no other navigation state object — each tab owns its own
/// `NavigationStack` — so this is deliberately a set of one-shot *requests* that
/// the relevant view consumes and clears, rather than a model of the whole
/// navigation tree.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    enum Tab: Int { case programs = 0, favorites = 1, downloads = 2, ai = 3 }

    @Published var tab: Tab = .programs
    /// A NER program the 節目 tab should push, once its catalog has loaded.
    @Published var pendingProgramId: String?
    /// A subscribed podcast the 節目 tab should push.
    @Published var pendingFeedId: String?
    /// Bumped to ask `ContentView` to present the full player sheet.
    @Published private(set) var openPlayerSignal = 0

    private init() {}

    func handle(_ url: URL) {
        guard url.scheme == WidgetLink.scheme else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }

        switch url.host {
        case "player":
            openPlayer()
        case "play":
            if let id = value("id"), let hit = EpisodeLookup.find(id) {
                PlayerManager.shared.play(hit.record, in: hit.queue)
            }
            openPlayer()
        case "show":
            guard let id = value("id") else { return }
            select(.programs)
            if value("podcast") == "1" {
                pendingFeedId = id
            } else {
                pendingProgramId = id
            }
        case "tab":
            switch value("name") {
            case "favorites": select(.favorites)
            case "downloads": select(.downloads)
            case "ai": select(.ai)
            default: select(.programs)
            }
        default:
            break
        }
    }

    private func openPlayer() {
        guard PlayerManager.shared.current != nil else { return }
        openPlayerSignal += 1
    }

    private func select(_ tab: Tab) {
        self.tab = tab
        #if targetEnvironment(macCatalyst)
        // The Mac window has no tab bar; its sidebar section is an AppStorage int.
        UserDefaults.standard.set(tab.rawValue, forKey: "macSidebarTab")
        #endif
    }
}

/// Finds a playable `EpisodeRecord` by id across everything the app holds
/// locally, plus the queue it should play inside. Widgets only ever surface
/// episodes drawn from these same sources, so a lookup that misses means the
/// user removed the episode after the snapshot was written.
@MainActor
enum EpisodeLookup {
    static func find(_ episodeId: String) -> (record: EpisodeRecord, queue: [EpisodeRecord])? {
        let queue = PlayerManager.shared.queue
        if let record = queue.first(where: { $0.id == episodeId }) {
            return (record, queue)
        }
        let downloads = DownloadManager.shared.records
        if let record = downloads.first(where: { $0.id == episodeId }) {
            return (record, downloads)
        }
        let favorites = FavoritesStore.shared.favorites
        if let record = favorites.first(where: { $0.id == episodeId }) {
            return (record, favorites)
        }
        for feed in PodcastStore.shared.feeds {
            if let record = feed.episodes.first(where: { $0.id == episodeId }) {
                return (record, feed.episodes)
            }
        }
        // Last resort: an episode the 最新單集 widget offered, which lives only in
        // the widget's own cache until it's played once.
        for program in FavoritesStore.shared.programs {
            let latest = WidgetLatestEpisodes.latest(programId: program.programId)
            if let record = latest.first(where: { $0.id == episodeId }) {
                return (record, latest)
            }
        }
        return nil
    }

    /// What a bare "play" button falls back to when nothing is loaded: the same
    /// first suggestion the widget was showing.
    static func firstSuggestion() -> (record: EpisodeRecord, queue: [EpisodeRecord])? {
        // Continuing whatever was last played beats offering an arbitrary
        // download, so try that first — even for a show that was never
        // favorited or downloaded, which is where `find` alone comes up empty.
        if let recent = RecentShowsStore.shared.shows.first {
            if let hit = find(recent.lastEpisodeId) { return hit }
            let episodes = ShowLookup.episodes(showId: recent.id, isPodcast: recent.isPodcast)
            if let start = episodes.first(where: { $0.id == recent.lastEpisodeId }) ?? episodes.first {
                return (start, episodes)
            }
        }
        let downloads = DownloadManager.shared.records
        if let record = downloads.last { return (record, downloads) }
        let favorites = FavoritesStore.shared.favorites
        if let record = favorites.last { return (record, favorites) }
        return nil
    }
}

/// A whole show as a playable queue. NER programs come from the browse cache,
/// which stores pages ascending from episode 1 — course order, which is exactly
/// the playlist we want.
@MainActor
enum ShowLookup {
    static func episodes(showId: String, isPodcast: Bool) -> [EpisodeRecord] {
        if isPodcast {
            return PodcastStore.shared.feed(id: showId)?.episodes ?? []
        }
        guard let program = program(id: showId) else { return [] }
        if let cached = CatalogCache.loadEpisodes(programId: showId), !cached.episodes.isEmpty {
            return cached.episodes.map {
                EpisodeRecord(episode: $0, programId: program.programId,
                              programName: program.name, language: program.language,
                              coverURL: program.coverURL?.absoluteString)
            }
        }
        // Never browsed on this device: the widget's own newest-episodes cache is
        // still enough to start the show.
        return WidgetLatestEpisodes.latest(programId: showId)
    }

    private static func program(id: String) -> Program? {
        FavoritesStore.shared.programs.first { $0.programId == id }
            ?? CatalogCache.loadPrograms()?.first { $0.programId == id }
    }
}

// MARK: - Widget button handling

extension PlayerManager: WidgetPlaybackHandling {
    func widgetTogglePlayPause() {
        if current == nil, let start = EpisodeLookup.firstSuggestion() {
            play(start.record, in: start.queue)
        } else {
            togglePlayPause()
        }
    }

    func widgetPlay(episodeId: String) {
        if current?.id == episodeId {
            togglePlayPause()
        } else if let hit = EpisodeLookup.find(episodeId) {
            play(hit.record, in: hit.queue)
        }
    }

    func widgetPlayShow(showId: String, isPodcast: Bool) {
        let episodes = ShowLookup.episodes(showId: showId, isPodcast: isPodcast)
        guard !episodes.isEmpty else { return }
        // Resume the episode this show was left on; a show never played starts at
        // the top, which for a sequential course means lesson 1.
        let resumeId = RecentShowsStore.shared.entry(id: showId)?.lastEpisodeId
        let start = resumeId.flatMap { id in episodes.first { $0.id == id } } ?? episodes[0]
        if current?.id == start.id {
            togglePlayPause()
        } else {
            // The whole show becomes the queue, so playback runs on through it.
            play(start, in: episodes)
        }
    }

    func widgetNext() { next() }

    func widgetSkip(_ seconds: Double) { skip(seconds) }
}
