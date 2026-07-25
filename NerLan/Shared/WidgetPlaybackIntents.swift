import AppIntents

// Compiled into both targets. The widget only ever *constructs* these (to wire
// up `Button(intent:)`); performing them is the app's job — intents conforming
// to `AudioPlaybackIntent` are run in the owning app's process, which the system
// launches in the background if needed. That's the only way a widget button can
// reach the app's `AVPlayer`.

/// What the app registers with `PlaybackBridge` so the shared intents can drive
/// playback without this file knowing `PlayerManager` exists.
@MainActor
protocol WidgetPlaybackHandling: AnyObject {
    /// Toggle the loaded episode, or start the widget's lead suggestion when
    /// nothing is loaded yet.
    func widgetTogglePlayPause()
    /// Play the given episode id, resolving it from downloads / favorites /
    /// podcasts / the current queue. Toggles instead if it's already loaded.
    func widgetPlay(episodeId: String)
    func widgetNext()
    func widgetSkip(_ seconds: Double)
}

enum PlaybackBridge {
    /// Set from the app delegate at launch; stays nil inside the widget
    /// extension, where `perform()` is never called.
    @MainActor static weak var handler: (any WidgetPlaybackHandling)?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放或暫停"
    static var description = IntentDescription("播放或暫停目前的單集。")
    static var isDiscoverable: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackBridge.handler?.widgetTogglePlayPause()
        return .result()
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "播放單集"
    static var description = IntentDescription("播放指定的單集。")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "單集編號")
    var episodeId: String

    init() {}

    init(episodeId: String) {
        self.episodeId = episodeId
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackBridge.handler?.widgetPlay(episodeId: episodeId)
        return .result()
    }
}

struct NextEpisodeIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "下一集"
    static var description = IntentDescription("跳到播放佇列的下一集。")
    static var isDiscoverable: Bool { false }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackBridge.handler?.widgetNext()
        return .result()
    }
}

/// ±15 s, matching the full player's skip buttons.
struct SkipIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "快轉或倒轉"
    static var description = IntentDescription("在目前的單集內前後跳 15 秒。")
    static var isDiscoverable: Bool { false }

    @Parameter(title: "秒數")
    var seconds: Double

    init() {}

    init(seconds: Double) {
        self.seconds = seconds
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PlaybackBridge.handler?.widgetSkip(seconds)
        return .result()
    }
}
