// Tier 3 Siri integration: the iOS 27 `.audio` app-schema domain.
//
// Where `SiriIntents.swift` registers *phrase templates* Siri matches literally,
// this file describes NerLan's catalog in terms the system already understands.
// Siri then handles arbitrary phrasing — "play the latest episode of X",
// "play something in NerLan" — by handing us an `AudioSearch` and asking the
// entity queries for matches, with no phrase of ours involved.
//
// The whole file is gated on `canImport(MediaIntents)`, which is false on the
// iOS 26 SDK. That keeps ordinary Xcode 26.3 builds compiling unchanged; the
// schemas only appear when built with Xcode 27+. `@available(iOS 27, *)` then
// gates them at runtime for devices still on iOS 26.
#if canImport(MediaIntents)

import AppIntents
import CoreSpotlight
import Foundation
import MediaIntents

// MARK: - Entities
//
// NerLan carries two kinds of content and the domain has a schema for each:
// Channel+ programs really are radio shows (國立教育廣播電台), and subscribed RSS
// shows are podcasts. Using the honest schema for each is the point — it's what
// lets Siri phrase "the latest episode of…" correctly for both.

@available(iOS 27.0, *)
@AppEntity(schema: .audio.radioShow)
struct RadioShowEntity: IndexedEntity {
    static let defaultQuery = RadioShowEntityQuery()

    /// The Channel+ `programId`.
    let id: String
    var title: String
    /// The show's language label, kept so the entity can offer "the Korean
    /// program" as a synonym — see `SiriNaming`. `let`, so the schema macro
    /// leaves it out of the entity's exposed properties.
    let language: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            synonyms: SiriNaming.synonyms(
                title: title, language: language, isPodcast: false,
                nickname: ShowNicknameStore.shared.nickname(for: id)))
    }

    // The schema macro rewrites the `var`s into `@Property`-backed computed
    // properties, so the synthesized memberwise init takes `EntityProperty`
    // values rather than plain ones. Every entity here spells its init out.
    init(id: String, title: String, language: String = "") {
        // Plain stored properties first: the schema macro turns `title` into a
        // computed property, and assigning one needs a fully initialized `self`.
        self.id = id
        self.language = language
        self.title = title
    }
}

@available(iOS 27.0, *)
struct RadioShowEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RadioShowEntity] {
        let all = await MediaCatalog.radioShows()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [RadioShowEntity] {
        await MediaCatalog.radioShows()
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.radioShowEpisode)
struct RadioShowEpisodeEntity: IndexedEntity {
    static let defaultQuery = RadioShowEpisodeEntityQuery()

    let id: String
    var title: String
    var showName: String?
    var releaseDate: Date?
    var show: RadioShowEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(showName ?? "")")
    }

    init(id: String, title: String, showName: String?, releaseDate: Date?, show: RadioShowEntity?) {
        self.id = id
        self.title = title
        self.showName = showName
        self.releaseDate = releaseDate
        self.show = show
    }
}

@available(iOS 27.0, *)
struct RadioShowEpisodeEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RadioShowEpisodeEntity] {
        let pool = await MediaCatalog.records(podcast: false)
        return identifiers.compactMap { id in
            pool.first { $0.id == id }.map(MediaCatalog.radioEpisode)
        }
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastShow)
struct PodcastShowEntity: IndexedEntity {
    static let defaultQuery = PodcastShowEntityQuery()

    /// The RSS feed URL — the identity `PodcastStore` already uses.
    let id: String
    var title: String
    var showDescription: String?
    /// See `RadioShowEntity.language`.
    let language: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            synonyms: SiriNaming.synonyms(
                title: title, language: language, isPodcast: true,
                nickname: ShowNicknameStore.shared.nickname(for: id)))
    }

    init(id: String, title: String, showDescription: String?, language: String = "") {
        self.id = id
        self.language = language
        self.title = title
        self.showDescription = showDescription
    }
}

@available(iOS 27.0, *)
struct PodcastShowEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PodcastShowEntity] {
        let all = await MediaCatalog.podcastShows()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [PodcastShowEntity] {
        await MediaCatalog.podcastShows()
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.podcastEpisode)
struct PodcastEpisodeEntity: IndexedEntity {
    static let defaultQuery = PodcastEpisodeEntityQuery()

    let id: String
    var title: String
    var showName: String?
    var show: PodcastShowEntity?
    var releaseDate: Date?
    var duration: Double?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(showName ?? "")")
    }

    init(id: String, title: String, showName: String?, show: PodcastShowEntity?,
         releaseDate: Date?, duration: Double?) {
        self.id = id
        self.title = title
        self.showName = showName
        self.show = show
        self.releaseDate = releaseDate
        self.duration = duration
    }
}

@available(iOS 27.0, *)
struct PodcastEpisodeEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PodcastEpisodeEntity] {
        let pool = await MediaCatalog.records(podcast: true)
        return identifiers.compactMap { id in
            pool.first { $0.id == id }.map(MediaCatalog.podcastEpisode)
        }
    }
}

/// Required by the `playAudio` schema, which can be handed the result of a
/// prior `warmupAudioQueue` call. NerLan doesn't implement warm-up — loading an
/// episode is a single `AVPlayerItem` swap, so there's nothing to pre-build — so
/// in practice the parameter always arrives nil. The type still has to exist for
/// the schema to validate.
/// `TransientAppEntity` because a warm-up result is a handle produced in one
/// interaction and consumed in the next — never something to look up by id. It
/// supplies `id` and `defaultQuery` for free; all we owe it is `init()`.
@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResultEntity: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "NerLan")
    }

    init() {}
}

/// Publishes the catalog into Spotlight.
///
/// Adopting the schemas is necessary but *not sufficient*: Apple Intelligence
/// finds app content through Spotlight's semantic index, so an unindexed app has
/// nothing for Siri to match a media request against — and Siri falls back to
/// Apple Podcasts. This is what puts NerLan's shows in the running at all.
@available(iOS 27.0, *)
enum MediaSpotlightIndex {
    /// A named index, per Apple's guidance — the default index is for prototyping.
    private static let index = CSSearchableIndex(name: "com.danielkao.NerLan.catalog")

    /// Courses run to hundreds of episodes; shows are what people name out loud,
    /// so episodes get a generous but bounded slice rather than the whole archive.
    private static let episodeLimit = 400

    @MainActor
    static func refresh() async {
        let radioShows = MediaCatalog.radioShows()
        let podcastShows = MediaCatalog.podcastShows()
        let radioEpisodes = MediaCatalog.records(podcast: false)
            .prefix(episodeLimit).map(MediaCatalog.radioEpisode)
        let podcastEpisodes = MediaCatalog.records(podcast: true)
            .prefix(episodeLimit).map(MediaCatalog.podcastEpisode)
        try? await index.indexAppEntities(radioShows)
        try? await index.indexAppEntities(podcastShows)
        try? await index.indexAppEntities(Array(radioEpisodes))
        try? await index.indexAppEntities(Array(podcastEpisodes))
    }
}

// MARK: - Search
//
// `IntentValueQuery` is what actually makes free-form Siri work: the system
// classifies the utterance and hands over an `AudioSearch`, and each query
// answers with whatever it can match. Returning nothing is fine — Siri asks the
// other entity types too.

@available(iOS 27.0, *)
extension RadioShowEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [RadioShowEntity] {
        let all = await MediaCatalog.radioShows()
        switch search.criteria {
        case .searchQuery(let query):
            return all.filter {
                SiriNaming.matches(query, aliases: MediaCatalog.aliases(
                    id: $0.id, title: $0.title, language: $0.language, isPodcast: false))
            }
        case .unspecified:
            return all
        case .url(let urls):
            let ids = await MediaCatalog.showIds(from: urls)
            return all.filter { ids.contains($0.id) }
        @unknown default:
            return []
        }
    }
}

@available(iOS 27.0, *)
extension PodcastShowEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [PodcastShowEntity] {
        let all = await MediaCatalog.podcastShows()
        switch search.criteria {
        case .searchQuery(let query):
            return all.filter {
                SiriNaming.matches(query, aliases: MediaCatalog.aliases(
                    id: $0.id, title: $0.title, language: $0.language, isPodcast: true))
            }
        case .unspecified:
            return all
        case .url(let urls):
            // A podcast's id *is* its feed URL, so a pasted/onscreen feed link
            // resolves directly here.
            let ids = await MediaCatalog.showIds(from: urls)
            return all.filter { ids.contains($0.id) }
        @unknown default:
            return []
        }
    }
}

@available(iOS 27.0, *)
extension RadioShowEpisodeEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [RadioShowEpisodeEntity] {
        await MediaCatalog.episodes(for: search, podcast: false).map(MediaCatalog.radioEpisode)
    }
}

@available(iOS 27.0, *)
extension PodcastEpisodeEntityQuery: IntentValueQuery {
    func values(for search: AudioSearch) async throws -> [PodcastEpisodeEntity] {
        await MediaCatalog.episodes(for: search, podcast: true).map(MediaCatalog.podcastEpisode)
    }
}

// MARK: - Play

/// Everything `playAudio` can be handed. One intent covers all four because the
/// schema takes a single `audioEntity`.
@available(iOS 27.0, *)
@UnionValue
enum NerLanAudioItem {
    case radioShow(RadioShowEntity)
    case radioShowEpisode(RadioShowEpisodeEntity)
    case podcastShow(PodcastShowEntity)
    case podcastEpisode(PodcastEpisodeEntity)
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum NerLanPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .shuffle: "隨機播放",
        .repeat: "重複播放",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum NerLanQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .next: "下一個播放",
        .tail: "加入佇列最後",
    ]
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct PlayAudioIntent {
    var audioEntity: NerLanAudioItem
    var playbackAttributes: Set<NerLanPlaybackAttributes>
    var warmupAudioQueueResult: WarmupAudioQueueResultEntity?
    var queueLocation: NerLanQueueInsertionLocation?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let hit = await MediaCatalog.resolve(audioEntity) else {
            throw SiriPlaybackError.noEpisodes(MediaCatalog.name(of: audioEntity))
        }
        let player = PlayerManager.shared
        // "Repeat" is the one attribute with a direct equivalent; the player has
        // no shuffle mode, so shuffling means handing it a shuffled queue.
        if playbackAttributes.contains(.repeat) { player.repeatMode = .all }
        let queue = playbackAttributes.contains(.shuffle) ? hit.queue.shuffled() : hit.queue

        if let queueLocation {
            // "Play X next" / "add X to the queue" — don't interrupt what's on.
            player.enqueue([hit.record], playNext: queueLocation == .next)
        } else {
            SiriPlayback.start(hit.record, in: queue)
        }
        return .result()
    }
}

// MARK: - Catalog

/// Bridges NerLan's stores to the schema entities. Everything here is read-only
/// and main-actor bound, because the stores are.
@available(iOS 27.0, *)
@MainActor
enum MediaCatalog {
    // MARK: Shows

    static func radioShows() -> [RadioShowEntity] {
        var seen = Set<String>()
        var out: [RadioShowEntity] = []
        func add(id: String, title: String, language: String) {
            guard seen.insert(id).inserted else { return }
            out.append(RadioShowEntity(id: id, title: title, language: language))
        }
        for show in RecentShowsStore.shared.shows where !show.isPodcast {
            add(id: show.id, title: show.name, language: show.language)
        }
        for program in FavoritesStore.shared.programs {
            add(id: program.programId, title: program.name, language: program.language)
        }
        return out
    }

    static func podcastShows() -> [PodcastShowEntity] {
        PodcastStore.shared.feeds.map {
            PodcastShowEntity(id: $0.id, title: $0.title,
                              showDescription: $0.descriptionText, language: $0.language)
        }
    }

    /// Spoken handles for a show entity, mirroring what its synonyms advertise.
    static nonisolated func aliases(id: String, title: String, language: String,
                                    isPodcast: Bool) -> [String] {
        SiriNaming.aliases(title: title, language: language, isPodcast: isPodcast,
                           nickname: ShowNicknameStore.shared.nickname(for: id))
    }

    // MARK: Episodes

    /// Every episode reachable without a network round-trip, of one kind.
    /// `audioLocale != nil` is the app's existing marker for a podcast record.
    static func records(podcast: Bool) -> [EpisodeRecord] {
        var seen = Set<String>()
        var out: [EpisodeRecord] = []
        func add(_ records: [EpisodeRecord]) {
            for record in records where (record.audioLocale != nil) == podcast {
                if seen.insert(record.id).inserted { out.append(record) }
            }
        }
        add(PlayerManager.shared.queue)
        add(DownloadManager.shared.records)
        add(FavoritesStore.shared.favorites)
        if podcast {
            for feed in PodcastStore.shared.feeds { add(feed.episodes) }
        } else {
            for program in FavoritesStore.shared.programs {
                add(WidgetLatestEpisodes.latest(programId: program.programId))
                guard let cached = CatalogCache.loadEpisodes(programId: program.programId) else { continue }
                add(cached.episodes.map {
                    EpisodeRecord(episode: $0, programId: program.programId,
                                  programName: program.name, language: program.language,
                                  coverURL: program.coverURL?.absoluteString)
                })
            }
        }
        return out
    }

    /// Episode-level search. A spoken query usually names the *show*, not the
    /// episode ("the latest episode of X"), so a show-name hit counts too — the
    /// system ranks what comes back.
    static func episodes(for search: AudioSearch, podcast: Bool) -> [EpisodeRecord] {
        let pool = records(podcast: podcast)
        switch search.criteria {
        case .searchQuery(let query):
            // The episode title itself, plus every handle its show answers to —
            // "the latest episode of the Korean podcast" names the show, not the
            // episode.
            return pool.filter { record in
                SiriNaming.matches(query, aliases: [record.title]
                    + aliases(id: record.programId, title: record.programName,
                              language: record.language, isPodcast: podcast))
            }
        case .unspecified:
            // "Play something": continuing beats an arbitrary pick.
            guard let hit = EpisodeLookup.firstSuggestion() else { return [] }
            return [hit.record].filter { ($0.audioLocale != nil) == podcast }
        case .url(let urls):
            // A deep link may name the episode directly, or only its show — in
            // which case offer that show's episodes.
            let episodeIds = episodeIds(from: urls)
            let showIds = showIds(from: urls)
            return pool.filter { episodeIds.contains($0.id) || showIds.contains($0.programId) }
        @unknown default:
            return []
        }
    }

    // MARK: Mapping

    static func radioEpisode(_ record: EpisodeRecord) -> RadioShowEpisodeEntity {
        RadioShowEpisodeEntity(
            id: record.id,
            title: record.title,
            showName: record.programName,
            releaseDate: record.playDate.flatMap(EpisodeRecord.parseISODate),
            show: RadioShowEntity(id: record.programId, title: record.programName,
                                  language: record.language))
    }

    static func podcastEpisode(_ record: EpisodeRecord) -> PodcastEpisodeEntity {
        PodcastEpisodeEntity(
            id: record.id,
            title: record.title,
            showName: record.programName,
            show: PodcastShowEntity(id: record.programId, title: record.programName,
                                    showDescription: nil, language: record.language),
            releaseDate: record.playDate.flatMap(EpisodeRecord.parseISODate),
            duration: record.durationSeconds.map(Double.init))
    }

    // MARK: Resolution

    static func name(of item: NerLanAudioItem) -> String {
        switch item {
        case .radioShow(let s): return s.title
        case .radioShowEpisode(let e): return e.title
        case .podcastShow(let s): return s.title
        case .podcastEpisode(let e): return e.title
        }
    }

    /// Turn whatever Siri picked into a starting episode plus the queue it should
    /// play inside.
    static func resolve(_ item: NerLanAudioItem) async -> (record: EpisodeRecord, queue: [EpisodeRecord])? {
        switch item {
        case .radioShow(let show):
            return await start(showId: show.id, name: show.title, isPodcast: false)
        case .podcastShow(let show):
            return await start(showId: show.id, name: show.title, isPodcast: true)
        case .radioShowEpisode(let item):
            return startEpisode(id: item.id, podcast: false)
        case .podcastEpisode(let item):
            return startEpisode(id: item.id, podcast: true)
        }
    }

    /// Reuses the Tier 1 helpers, including their network fallback for a program
    /// that was favorited but never browsed on this device.
    private static func start(showId: String, name: String, isPodcast: Bool)
        async -> (record: EpisodeRecord, queue: [EpisodeRecord])?
    {
        let show = ShowEntity(id: showId, name: name, language: "", isPodcast: isPodcast)
        let episodes = await SiriPlayback.episodes(for: show)
        guard let start = SiriPlayback.resumePoint(of: show, in: episodes) else { return nil }
        return (start, episodes)
    }

    private static func startEpisode(id: String, podcast: Bool)
        -> (record: EpisodeRecord, queue: [EpisodeRecord])?
    {
        if let hit = EpisodeLookup.find(id) { return hit }
        let pool = records(podcast: podcast)
        guard let record = pool.first(where: { $0.id == id }) else { return nil }
        return (record, pool.filter { $0.programId == record.programId })
    }

    // MARK: URL criteria

    /// Show ids referenced by a URL: our own `nerlan://show?id=` deep links, and
    /// — for podcasts — the feed URL itself, which is the id.
    static func showIds(from urls: [URL]) -> Set<String> {
        var ids = Set<String>()
        for url in urls {
            ids.insert(url.absoluteString)
            guard url.scheme == WidgetLink.scheme,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let id = items.first(where: { $0.name == "id" })?.value else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Episode ids referenced by `nerlan://play?id=` deep links.
    static func episodeIds(from urls: [URL]) -> Set<String> {
        var ids = Set<String>()
        for url in urls where url.scheme == WidgetLink.scheme {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let id = items.first(where: { $0.name == "id" })?.value else { continue }
            ids.insert(id)
        }
        return ids
    }

}

#endif
