import AppIntents
import Foundation
import UIKit

// Siri / Shortcuts surface. App-target only (unlike `WidgetPlaybackIntents.swift`,
// which is shared with the widget extension) — these intents run in the app
// process and talk to `PlayerManager` directly, so there's no reason to compile
// them into the extension.
//
// Two things are worth knowing before editing this file:
//
//  * A spoken phrase MUST contain `\(.applicationName)`; Siri has no other way to
//    route an utterance to us. "在 NerLan 播放…" / "…in NerLan" isn't politeness,
//    it's the API contract.
//  * Siri only voice-matches parameter values that `suggestedEntities()` has
//    published ahead of time. Anything not in that list can be typed in the
//    Shortcuts app but can never be *spoken*. Hence `NerLanShortcuts
//    .updateAppShortcutParameters()` on every subscription/favorite change.
//
// Plain transport control (pause, resume, next, skip 30 seconds) deliberately has
// no intent here: `PlayerManager` already registers `MPRemoteCommandCenter`
// handlers, so Siri drives those for free whenever NerLan is the now-playing app.

/// Cover art for Siri and Spotlight, as embeddable JPEG bytes.
///
/// Spotlight shows the app icon when a result carries no thumbnail of its own —
/// which is why NerLan's entries looked bare next to other media apps. The bytes
/// have to be available *synchronously*, because `displayRepresentation` is a
/// plain computed property, and they have to be embedded rather than referenced:
/// `CoverImageCache`'s files live in Caches, which the OS may purge, leaving a
/// file URL dangling inside Spotlight's index. So the indexer warms this cache
/// asynchronously first, and the entities read from it for free afterwards.
enum SiriCoverThumbnails {
    /// Plenty for a Spotlight row or a Siri card, small enough to embed per entity.
    private static let pixelSize: CGFloat = 256

    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]

    static func data(for coverURL: String?) -> Data? {
        guard let coverURL else { return nil }
        lock.lock(); defer { lock.unlock() }
        return cache[coverURL]
    }

    static func image(for coverURL: String?) -> DisplayRepresentation.Image? {
        data(for: coverURL).map { DisplayRepresentation.Image(data: $0) }
    }

    /// Fetch and downscale anything not already held. Covers are shared across a
    /// whole program, so the unique set is far smaller than the entity count.
    static func warm(_ coverURLs: [String?]) async {
        for coverURL in Set(coverURLs.compactMap { $0 }) {
            if data(for: coverURL) != nil { continue }
            guard let url = URL(string: coverURL),
                  let image = await CoverImageCache.shared.image(for: url),
                  let jpeg = downscaled(image) else { continue }
            lock.lock(); cache[coverURL] = jpeg; lock.unlock()
        }
    }

    private static func downscaled(_ image: UIImage) -> Data? {
        let size = CGSize(width: pixelSize, height: pixelSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.8)
    }
}

/// The one call every store makes when the set of shows changes.
///
/// Two things have to be re-announced, and forgetting either is silent: the App
/// Shortcut parameter values Siri is allowed to *hear*, and (iOS 27) the Spotlight
/// index Apple Intelligence *searches* when it routes a media request.
enum SiriCatalog {
    static func publish() {
        // Names first, synchronously — fetching artwork can hit the network, and
        // Siri knowing what to listen for shouldn't wait on a cover download.
        NerLanShortcuts.updateAppShortcutParameters()
        Task { @MainActor in
            await SiriCoverThumbnails.warm(ShowCatalog.all().map(\.coverURL))
            // Re-publish: the first pass serialized the entities before any
            // artwork existed, so without this the cards stay bare until the
            // next catalog change. Cheap on the second pass — the covers are
            // cached by then.
            NerLanShortcuts.updateAppShortcutParameters()
            #if canImport(MediaIntents)
            if #available(iOS 27.0, *) {
                await MediaSpotlightIndex.refresh()
            }
            #endif
        }
    }
}

// MARK: - Show entity

/// One playable show — a NER program or a subscribed podcast — as Siri and the
/// Shortcuts app see it. Deliberately flat: the entity is a name the user can say
/// plus enough identity to hand back to `ShowLookup`.
struct ShowEntity: AppEntity, Identifiable {
    /// `programId` for a NER program, the feed URL for a podcast — the same
    /// identity `ShowLookup`/`RecentShowsStore` use.
    let id: String
    let name: String
    let language: String
    let isPodcast: Bool
    /// Artwork for the Siri card and Spotlight row; nil until the cover has been
    /// warmed into `SiriCoverThumbnails`.
    var coverURL: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "節目")
    }

    /// Nickname, romanization and language aliases, so a show whose title Siri
    /// can't transcribe is still reachable — see `SiriNaming`.
    var aliases: [String] {
        SiriNaming.aliases(title: name, language: language, isPodcast: isPodcast,
                           nickname: ShowNicknameStore.shared.nickname(for: id))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(language)",
            image: SiriCoverThumbnails.image(for: coverURL),
            synonyms: SiriNaming.synonyms(
                title: name, language: language, isPodcast: isPodcast,
                nickname: ShowNicknameStore.shared.nickname(for: id)))
    }

    static var defaultQuery = ShowEntityQuery()
}

struct ShowEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [ShowEntity.ID]) async throws -> [ShowEntity] {
        let all = await ShowCatalog.all()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    /// Free-text match, used when the Shortcuts app searches and when Siri hands
    /// back a transcription that didn't land on an exact suggested entity.
    func entities(matching string: String) async throws -> [ShowEntity] {
        await ShowCatalog.all().filter { SiriNaming.matches(string, aliases: $0.aliases) }
    }

    /// The set Siri is allowed to hear. Everything the user could plausibly mean,
    /// which for this app is small enough to publish whole.
    func suggestedEntities() async throws -> [ShowEntity] {
        await ShowCatalog.all()
    }
}

/// Every show the app can start without a catalog browse, newest-interest first.
@MainActor
enum ShowCatalog {
    static func all() -> [ShowEntity] {
        var seen = Set<String>()
        var out: [ShowEntity] = []
        func add(_ entity: ShowEntity) {
            guard seen.insert(entity.id).inserted else { return }
            out.append(entity)
        }
        // Recents lead: the show someone names out loud is usually one they're in
        // the middle of, and this is the only source that covers programs which
        // were never favorited.
        for show in RecentShowsStore.shared.shows {
            add(ShowEntity(id: show.id, name: show.name, language: show.language,
                           isPodcast: show.isPodcast, coverURL: show.coverURL))
        }
        for feed in PodcastStore.shared.feeds {
            add(ShowEntity(id: feed.id, name: feed.title, language: feed.language,
                           isPodcast: true, coverURL: feed.coverURL))
        }
        for program in FavoritesStore.shared.programs {
            add(ShowEntity(id: program.programId, name: program.name,
                           language: program.language, isPodcast: false,
                           coverURL: program.coverURL?.absoluteString))
        }
        return out
    }

    /// Kept as the catalog's spelling of `SiriNaming.fold`, which owns the
    /// matching rules for both tiers.
    nonisolated static func fold(_ s: String) -> String { SiriNaming.fold(s) }
}

// MARK: - Errors

enum SiriPlaybackError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noEpisodes(String)
    case nothingRecent

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noEpisodes(let name):
            return "找不到「\(name)」的單集，請先在 NerLan 裡打開這個節目。"
        case .nothingRecent:
            return "NerLan 還沒有播放紀錄。"
        }
    }
}

// MARK: - Playback helpers

@MainActor
enum SiriPlayback {
    /// Episodes for a show, falling back to the network for a NER program that was
    /// favorited but never browsed on this device (its catalog cache is empty and
    /// the widget's newest-episode cache may not have run yet). Siri intents get a
    /// real async context, so unlike the widget path this can wait for a fetch.
    static func episodes(for show: ShowEntity) async -> [EpisodeRecord] {
        let local = ShowLookup.episodes(showId: show.id, isPodcast: show.isPodcast)
        if !local.isEmpty || show.isPodcast { return local }
        guard let program = FavoritesStore.shared.programs.first(where: { $0.programId == show.id })
                ?? CatalogCache.loadPrograms()?.first(where: { $0.programId == show.id }),
              let fetched = try? await ChannelPlusAPI.episodes(programId: show.id, page: 1)
        else { return [] }
        return fetched.episodes.map {
            EpisodeRecord(episode: $0, programId: program.programId,
                          programName: program.name, language: program.language,
                          coverURL: program.coverURL?.absoluteString)
        }
    }

    /// Start `record` inside `queue`. Unlike the widget's `widgetPlayShow`, this
    /// never toggles: a spoken "play X" that pauses X would be a bug.
    static func start(_ record: EpisodeRecord, in queue: [EpisodeRecord]) {
        let player = PlayerManager.shared
        if player.current?.id == record.id {
            player.play()   // resume if paused; no-op if already rolling
        } else {
            player.play(record, in: queue)
        }
    }

    /// Where a show should resume: the episode it was left on, else the first
    /// (which for a sequential NER course means lesson 1).
    static func resumePoint(of show: ShowEntity, in episodes: [EpisodeRecord]) -> EpisodeRecord? {
        let resumeId = RecentShowsStore.shared.entry(id: show.id)?.lastEpisodeId
        return resumeId.flatMap { id in episodes.first { $0.id == id } } ?? episodes.first
    }

    /// Newest episode of a show. Podcast feed order isn't guaranteed, so sort.
    static func newest(of show: ShowEntity, in episodes: [EpisodeRecord]) -> EpisodeRecord? {
        if show.isPodcast {
            return episodes.max { ($0.playDate ?? "") < ($1.playDate ?? "") }
        }
        // NER courses page ascending, and the widget cache holds the tail newest
        // first — prefer that when it's warm, else take the end of the archive.
        if let cached = WidgetLatestEpisodes.latest(programId: show.id).first { return cached }
        return episodes.max { ($0.episodeNo ?? 0) < ($1.episodeNo ?? 0) } ?? episodes.last
    }
}

// MARK: - Intents

/// "在 NerLan 播放 <節目>" — resumes the show where it was left off.
struct SiriPlayShowIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放節目"
    static var description = IntentDescription("播放指定的節目，從上次停下的地方繼續。")

    @Parameter(title: "節目")
    var show: ShowEntity

    init() {}
    init(show: ShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult {
        let episodes = await SiriPlayback.episodes(for: show)
        guard let start = SiriPlayback.resumePoint(of: show, in: episodes) else {
            throw SiriPlaybackError.noEpisodes(show.name)
        }
        SiriPlayback.start(start, in: episodes)
        return .result()
    }
}

/// "在 NerLan 播放 <節目> 的最新一集".
struct SiriPlayLatestEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放最新一集"
    static var description = IntentDescription("播放指定節目最新的一集。")

    @Parameter(title: "節目")
    var show: ShowEntity

    init() {}
    init(show: ShowEntity) { self.show = show }

    @MainActor
    func perform() async throws -> some IntentResult {
        let episodes = await SiriPlayback.episodes(for: show)
        guard let latest = SiriPlayback.newest(of: show, in: episodes) else {
            throw SiriPlaybackError.noEpisodes(show.name)
        }
        // Queue the whole show so playback carries on past the newest episode
        // when it's the widget-cache copy that isn't in `episodes`.
        SiriPlayback.start(latest, in: episodes.contains(latest) ? episodes : [latest] + episodes)
        return .result()
    }
}

/// "在 NerLan 繼續上次的節目" — no parameter, so this is the phrase that always
/// works even when Siri can't make out a show name.
struct SiriResumeLastShowIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "繼續上次的節目"
    static var description = IntentDescription("從上次停下的地方繼續播放。")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let hit = EpisodeLookup.firstSuggestion() else {
            throw SiriPlaybackError.nothingRecent
        }
        SiriPlayback.start(hit.record, in: hit.queue)
        return .result()
    }
}

/// Playback speed as a spoken value. Mirrors `PlayerManager.availableRates` —
/// keep the two in step.
enum SiriPlaybackRate: String, AppEnum {
    case half = "0.5"
    case threeQuarters = "0.75"
    case normal = "1.0"
    case fast125 = "1.25"
    case fast15 = "1.5"
    case fast175 = "1.75"
    case double = "2.0"

    var value: Float { Float(rawValue) ?? 1.0 }

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "播放速度")
    }

    static var caseDisplayRepresentations: [SiriPlaybackRate: DisplayRepresentation] = [
        .half: "0.5 倍速",
        .threeQuarters: "0.75 倍速",
        .normal: "正常速度",
        .fast125: "1.25 倍速",
        .fast15: "1.5 倍速",
        .fast175: "1.75 倍速",
        .double: "2 倍速",
    ]
}

/// "在 NerLan 用 1.5 倍速播放" — worth a voice command in a language-learning app,
/// where slowing a passage down is a normal part of listening.
struct SiriSetPlaybackRateIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "設定播放速度"
    static var description = IntentDescription("調整 NerLan 的播放速度。")

    @Parameter(title: "速度")
    var rate: SiriPlaybackRate

    init() {}
    init(rate: SiriPlaybackRate) { self.rate = rate }

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayerManager.shared.playbackRate = rate.value
        return .result()
    }
}

/// "我在 NerLan 聽了多久" — Siri speaks the answer back, no app launch.
struct SiriListeningStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "查詢學習時間"
    static var description = IntentDescription("問問自己這週在 NerLan 聽了多久。")
    /// Reading a number aloud is the whole point; opening the app would bury it.
    static var openAppWhenRun = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let stats = ListeningStatsStore.shared
        let today = Int(stats.secondsToday / 60)
        let week = Int(stats.secondsThisWeek / 60)
        let streak = stats.currentStreak
        let dialog: IntentDialog = streak > 1
            ? "今天聽了 \(today) 分鐘，這週累計 \(week) 分鐘，已經連續 \(streak) 天了。"
            : "今天聽了 \(today) 分鐘，這週累計 \(week) 分鐘。"
        return .result(dialog: dialog)
    }
}

// MARK: - App Shortcuts

/// The phrases Siri listens for. Both Chinese and English are registered because
/// Siri matches in whatever language it's set to, and this app's audience is
/// likely to run either. `AppShortcuts.strings` can localize them further.
struct NerLanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SiriPlayShowIntent(),
            // App name FIRST in the English variants. "Play <x> in NerLan" is a
            // media-shaped utterance, and Siri's media domain classifies it before
            // App Shortcut matching gets a turn — which is how these requests end
            // up in Apple Podcasts. Leading with the app name makes the utterance
            // unambiguously app-directed.
            phrases: [
                "\(.applicationName) play \(\.$show)",
                "In \(.applicationName) play \(\.$show)",
                "Ask \(.applicationName) to play \(\.$show)",
                "Play \(\.$show) in \(.applicationName)",
                "Play \(\.$show) on \(.applicationName)",
                "\(.applicationName) 播放 \(\.$show)",
                "在 \(.applicationName) 播放 \(\.$show)",
                "用 \(.applicationName) 播放 \(\.$show)",
            ],
            shortTitle: "播放節目",
            systemImageName: "play.circle.fill"
        )

        AppShortcut(
            intent: SiriPlayLatestEpisodeIntent(),
            phrases: [
                "\(.applicationName) play the latest episode of \(\.$show)",
                "Ask \(.applicationName) for the latest episode of \(\.$show)",
                "Play the latest episode of \(\.$show) in \(.applicationName)",
                "Play the newest episode of \(\.$show) on \(.applicationName)",
                "\(.applicationName) 播放 \(\.$show) 的最新一集",
                "在 \(.applicationName) 播放 \(\.$show) 的最新一集",
            ],
            shortTitle: "播放最新一集",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: SiriResumeLastShowIntent(),
            phrases: [
                "在 \(.applicationName) 繼續上次的節目",
                "繼續播放 \(.applicationName)",
                "\(.applicationName) 繼續收聽",
                "Play the last program in \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue listening in \(.applicationName)",
            ],
            shortTitle: "繼續上次的節目",
            systemImageName: "play.circle"
        )

        AppShortcut(
            intent: SiriSetPlaybackRateIntent(),
            phrases: [
                "在 \(.applicationName) 用 \(\.$rate) 播放",
                "把 \(.applicationName) 調整為 \(\.$rate)",
                "Set \(.applicationName) to \(\.$rate)",
            ],
            shortTitle: "設定播放速度",
            systemImageName: "speedometer"
        )

        AppShortcut(
            intent: SiriListeningStatsIntent(),
            phrases: [
                "我在 \(.applicationName) 聽了多久",
                "\(.applicationName) 學習紀錄",
                "How long did I listen in \(.applicationName)",
                "\(.applicationName) listening stats",
            ],
            shortTitle: "學習紀錄",
            systemImageName: "chart.bar.fill"
        )
    }
}
