import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// High-frequency playback position, split out of `PlayerManager`. The 0.5s
/// time-observer ticks update this object, so they invalidate only views that
/// observe the clock (the full-player scrubber) — not every list row, mini
/// player, or `ContentView` that observes `PlayerManager` for `current` /
/// `isPlaying`, which is what made the lists scroll-lag during playback.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

/// App-wide audio player. Holds the current queue (an episode list from one
/// program view, favorites, or downloads) and drives AVPlayer + lock-screen controls.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var current: EpisodeRecord?
    @Published private(set) var queue: [EpisodeRecord] = []
    @Published private(set) var isPlaying = false

    /// Playback position. Kept on a separate observable so frequent time updates
    /// don't re-render the lists/mini player. See `PlaybackClock`.
    let clock = PlaybackClock()

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    enum RepeatMode: Int {
        case off = 0, all = 1, one = 2
    }

    @Published var repeatMode: RepeatMode =
        RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "repeatMode")) ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    @Published var playbackRate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")
            player.defaultRate = playbackRate
            if isPlaying { player.rate = playbackRate }
            updateNowPlayingElapsed()
        }
    }

    /// The `[start, end)` region currently looping for shadowing, or nil. Set and
    /// cleared via `loopSegment`/`clearLoop`; published so the UI can reflect that
    /// a sentence loop is active. Changes only when a loop is armed/cleared, not on
    /// each loop pass, so it doesn't add per-tick re-renders.
    @Published private(set) var loopRegion: ClosedRange<Double>?

    /// Bumped when a finite sentence loop finishes its last pass. The shadowing UI
    /// observes this to auto-start recording the learner's repeat.
    @Published private(set) var loopFinishedSignal = 0

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Fires when playback crosses the loop region's end. Tied to the player (not
    /// the item), so it survives `replaceCurrentItem` and is removed explicitly.
    private var boundaryObserver: Any?
    /// Remaining passes for a finite loop; nil while looping forever.
    private var loopRemaining: Int?
    /// Wall-clock timestamp of the last playback tick, used to accumulate real
    /// time spent listening (independent of playback rate). Nil while paused/idle;
    /// gaps larger than a few seconds (pause, seek, backgrounding) are discarded.
    private var lastTick: Date?
    /// When the resume position was last written to disk. Saving on every 0.5s
    /// tick would be pointless churn, so it's throttled the way the listening
    /// stats are.
    private var lastPositionSave: Date?
    /// The caching item currently streaming (when cache-on-stream is enabled),
    /// plus the episode it belongs to, so its completed buffer is saved under the
    /// right id. Only one is ever live — the previous one is stopped on each load.
    private var cachingItem: CachingPlayerItem?
    /// The episode the caching item is streaming, kept whole so the finished
    /// file can be filed with its record (the Downloads tab lists cached copies).
    private var cachingRecord: EpisodeRecord?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        player.defaultRate = playbackRate
        setupRemoteCommands()
        // Interruptions (Siri, calls, another app taking audio) pause the player
        // without going through pause(), leaving isPlaying stale at true — and a
        // stale true makes play()'s guard swallow the lock screen's next play
        // command entirely. Track them, and resume when the system says to.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        }
        // If mediaserverd crashes, every session setting is lost; re-apply the
        // category so the next play() / load() works instead of staying silent.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { _ in
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.clock.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite,
                   d != self.clock.duration {
                    self.clock.duration = d
                    // Duration just became known (or was re-estimated): push one
                    // now-playing update so the lock screen learns the length.
                    // Elapsed time needs no per-tick pushes — the system
                    // extrapolates it from the last update and the rate, so
                    // updates happen only on play/pause/seek/rate/track changes.
                    self.updateNowPlayingElapsed()
                }
                self.accumulateListening()
            }
        }
    }

    var hasNext: Bool {
        guard let current, let i = queue.firstIndex(of: current) else { return false }
        return i + 1 < queue.count || (repeatMode == .all && !queue.isEmpty)
    }

    var hasPrevious: Bool {
        guard let current, let i = queue.firstIndex(of: current) else { return false }
        return i > 0
    }

    func play(_ record: EpisodeRecord, in newQueue: [EpisodeRecord]) {
        queue = newQueue
        load(record)
    }

    /// Add to the queue without disturbing what's playing — "play this next" /
    /// "add this to the queue", which the iOS 27 audio schema can ask for. With
    /// nothing loaded there's no "next", so the records just become the queue.
    func enqueue(_ records: [EpisodeRecord], playNext: Bool) {
        let fresh = records.filter { !queue.contains($0) }
        guard !fresh.isEmpty else { return }
        guard let current, let i = queue.firstIndex(of: current) else {
            queue.append(contentsOf: fresh)
            return
        }
        queue.insert(contentsOf: fresh, at: playNext ? i + 1 : queue.count)
    }

    /// Credit real time spent in the playing state to the listening stats. Called
    /// on each periodic tick; gaps from pause/seek/backgrounding (delta ≥ 5s) are
    /// dropped rather than counted as listening.
    private func accumulateListening() {
        guard isPlaying else { lastTick = nil; return }
        let now = Date()
        if let last = lastTick {
            let delta = now.timeIntervalSince(last)
            if delta > 0, delta < 5 {
                ListeningStatsStore.shared.addListening(seconds: delta, program: current)
            }
        }
        lastTick = now
        if lastPositionSave.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
            lastPositionSave = now
            savePosition()
        }
    }

    /// Persist where the current episode is, so reopening it resumes. The store
    /// drops positions at either edge, so this can be called freely.
    private func savePosition() {
        guard let current, clock.currentTime > 0 else { return }
        PlaybackPositionStore.shared.record(episodeId: current.id,
                                            position: clock.currentTime,
                                            duration: clock.duration)
    }

    private func load(_ record: EpisodeRecord) {
        // Pin where the outgoing episode got to before anything is torn down.
        savePosition()
        lastPositionSave = nil
        // Discard any still-streaming caching item from the previous episode.
        cachingItem?.stopDownloading()
        cachingItem = nil
        cachingRecord = nil
        lastTick = nil   // don't count the gap across an episode change
        clearLoop()      // a sentence loop never carries across episodes

        // Prefer an offline copy — an explicit download first, then a streamed
        // cache copy — and only then stream from the network.
        let item: AVPlayerItem
        if let local = DownloadManager.shared.localAssetURL(episodeId: record.id) {
            item = AVPlayerItem(asset: AVURLAsset(url: local))
        } else if let cached = DownloadManager.shared.cachedAssetURL(episodeId: record.id) {
            item = AVPlayerItem(asset: AVURLAsset(url: cached))
            // Backfills records for files cached before records were kept, so
            // they surface in the Downloads tab once replayed.
            DownloadManager.shared.noteCachedEpisode(record)
        } else if let remote = record.audio.flatMap(URL.init(string:)) {
            if SettingsStore.shared.cacheStreamedAudio {
                let caching = CachingPlayerItem(url: remote)
                caching.cacheDelegate = self
                cachingItem = caching
                cachingRecord = record
                item = caching
            } else {
                item = AVPlayerItem(asset: AVURLAsset(url: remote))
            }
        } else {
            return
        }
        current = record
        clock.duration = 0
        clock.currentTime = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.playbackDidFinish() }
        }
        player.replaceCurrentItem(with: item)
        // Pick up where this episode was left. The seek is queued against the
        // fresh item, so it applies as soon as the asset is ready; setting the
        // clock now keeps the scrubber and lock screen from flashing 0:00.
        if let resume = PlaybackPositionStore.shared.position(for: record.id) {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            clock.currentTime = resume
        }
        RecentShowsStore.shared.note(record)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    /// Resume playback if paused — the explicit counterpart to `pause()`, for
    /// remote commands whose meaning is "play", not "toggle". No-op with
    /// nothing loaded (the mini player is hidden then anyway).
    func play() {
        guard !isPlaying, player.currentItem != nil else { return }
        // After the last queue item finishes, the player parks at the end of the
        // item; play() there produces no audio while the UI flips to "playing".
        // Restart the episode instead.
        if clock.duration > 0, clock.currentTime >= clock.duration - 0.5 {
            seek(to: 0)
        }
        // While paused in the background the system can deactivate our audio
        // session (an interruption, or reclaiming an idle session). A background
        // app playing on an inactive session silently fails — the rate snaps
        // back to 0 — which broke resuming from the lock screen after a longer
        // pause. Reactivate first, as load() and loopSegment() already do.
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        lastTick = Date()
        updateNowPlayingElapsed()
    }

    /// Auto-advance when an episode finishes; honors the repeat mode.
    private func playbackDidFinish() {
        ListeningStatsStore.shared.noteCompleted()
        // Finished: drop the resume point so replaying starts from the top.
        if let current { PlaybackPositionStore.shared.clear(episodeId: current.id) }
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            isPlaying = true
            return
        }
        next()
    }

    func next() {
        guard let current, let i = queue.firstIndex(of: current) else { return }
        if i + 1 < queue.count {
            load(queue[i + 1])
        } else if repeatMode == .all, let first = queue.first {
            load(first)
        } else {
            isPlaying = false
        }
    }

    func previous() {
        guard let current, let i = queue.firstIndex(of: current), i > 0 else { return }
        load(queue[i - 1])
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        clock.currentTime = seconds
        updateNowPlayingElapsed()
    }

    /// Frame-accurate seek for the sentence loop: the default seek's unbounded
    /// tolerance can land noticeably off the cue, clipping the start of the
    /// sentence being shadowed or pre-rolling the previous one. The scrubber
    /// and skip buttons keep the coarse (faster) `seek(to:)`.
    private func seekPrecisely(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        clock.currentTime = seconds
        updateNowPlayingElapsed()
    }

    func skip(_ delta: Double) {
        seek(to: max(0, min(clock.currentTime + delta, clock.duration > 0 ? clock.duration : .greatestFiniteMagnitude)))
    }

    // MARK: - Segment loop (shadowing)

    /// Loop a single `[start, end)` region — the core of shadowing's sentence
    /// repeat. `times == nil` loops forever; a finite count plays the segment that
    /// many times, then clears the loop so normal sequential playback resumes (no
    /// inserted gap). Replaces any region already looping. The end is matched with
    /// a boundary time observer, which is exact — the 0.5s periodic observer would
    /// overshoot by up to half a second.
    func loopSegment(start: Double, end: Double, times: Int? = nil) {
        let from = max(0, start)
        guard end > from else { return }
        removeBoundaryObserver()
        loopRegion = from...end
        loopRemaining = times
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            Task { @MainActor [weak self] in self?.loopBoundaryReached(from: from) }
        }
        seekPrecisely(to: from)
        if !isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            lastTick = Date()
            updateNowPlayingElapsed()
        }
    }

    private func loopBoundaryReached(from: Double) {
        guard loopRegion != nil else { return }
        if let remaining = loopRemaining {
            if remaining > 1 {
                loopRemaining = remaining - 1
                seekPrecisely(to: from)
            } else {
                // Finite count done: stop on the sentence and signal the shadowing
                // UI, which auto-starts recording the learner's turn.
                clearLoop()
                pause()
                loopFinishedSignal += 1
            }
        } else {
            seekPrecisely(to: from)
        }
    }

    /// Sync state when the system interrupts playback (the player is already
    /// paused by iOS at that point), and resume once the interruption ends if
    /// the system deems resumption appropriate (e.g. after a short call).
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            guard isPlaying else { return }
            isPlaying = false
            lastTick = nil
            savePosition()
            ListeningStatsStore.shared.flush()
            updateNowPlayingElapsed()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume) { play() }
        @unknown default:
            break
        }
    }

    /// Pause playback without touching the queue or loop. Used when the recorder
    /// takes the mic, when the learner plays back their own voice, and when a
    /// finite sentence loop finishes.
    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        lastTick = nil
        savePosition()
        ListeningStatsStore.shared.flush()
        updateNowPlayingElapsed()
    }

    /// Hand the audio session to the recorder: drop any loop, pause, and switch to
    /// play-and-record so the mic is live. Paired with `endRecordingSession`.
    func beginRecordingSession() {
        clearLoop()
        pause()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .spokenAudio,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    /// Restore the normal playback session after recording. Leaves playback paused
    /// — the learner decides whether to replay the original or their own take.
    func endRecordingSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    /// Stop any active segment loop; playback continues from wherever it is.
    func clearLoop() {
        removeBoundaryObserver()
        loopRegion = nil
        loopRemaining = nil
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    // MARK: - Lock screen / control center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // play/pause carry explicit meaning (CarPlay, watch, and a desynced
        // Control Center can send "play" while already playing — toggling there
        // would pause and make the desync sticky); headset taps send the
        // dedicated toggle command, which without a handler does nothing.
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
        // "Hey Siri, skip forward 30 seconds" / "go back 15 seconds" arrive as
        // these, and without handlers they silently do nothing. Honor the interval
        // the event carries — Siri can ask for any amount.
        //
        // Deliberately NO `preferredIntervals`: setting it makes the Now Playing
        // UI draw ±N second skip buttons, and those take visual precedence over
        // next/previous track even when both commands are enabled. The lock screen
        // should keep next/previous *episode* for a sequential course, so the skip
        // commands stay voice-only.
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(e.interval) }
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.skip(-e.interval) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.programName,
            MPMediaItemPropertyAlbumTitle: current.language,
        ]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.currentTime
        if clock.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = clock.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let coverString = current.coverURL, let url = URL(string: coverString) {
            let episodeId = current.id
            Task { [weak self] in
                // Same two-tier cache the list rows use — sequential episodes of
                // one program share a cover, so this is usually a memory hit
                // instead of a fresh download per episode.
                guard let image = await CoverImageCache.shared.image(for: url) else { return }
                // Skipped to another episode while the fetch was in flight?
                // Don't stamp the old episode's cover onto the new one.
                guard let self, self.current?.id == episodeId else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = clock.currentTime
        if clock.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = clock.duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension PlayerManager: CachingPlayerItemDelegate {
    nonisolated func cachingPlayerItem(_ item: CachingPlayerItem, didFinishDownloadingTo fileURL: URL) {
        Task { @MainActor [weak self] in
            guard let self, item === self.cachingItem, let record = self.cachingRecord else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            DownloadManager.shared.storeCachedAudio(fileAt: fileURL, record: record)
        }
    }
}
