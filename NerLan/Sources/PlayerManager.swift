import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// App-wide audio player. Holds the current queue (an episode list from one
/// program view, favorites, or downloads) and drives AVPlayer + lock-screen controls.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var current: EpisodeRecord?
    @Published private(set) var queue: [EpisodeRecord] = []
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    @Published var playbackRate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1.0 {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: "playbackRate")
            player.defaultRate = playbackRate
            if isPlaying { player.rate = playbackRate }
            updateNowPlayingElapsed()
        }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        player.defaultRate = playbackRate
        setupRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = time.seconds
                if let d = self.player.currentItem?.duration.seconds, d.isFinite {
                    self.duration = d
                }
                self.updateNowPlayingElapsed()
            }
        }
    }

    var hasNext: Bool {
        guard let current, let i = queue.firstIndex(of: current) else { return false }
        return i + 1 < queue.count
    }

    var hasPrevious: Bool {
        guard let current, let i = queue.firstIndex(of: current) else { return false }
        return i > 0
    }

    func play(_ record: EpisodeRecord, in newQueue: [EpisodeRecord]) {
        queue = newQueue
        load(record)
    }

    private func load(_ record: EpisodeRecord) {
        // Prefer the offline copy when one exists.
        let asset: AVURLAsset
        if let local = DownloadManager.shared.localAssetURL(episodeId: record.id) {
            asset = AVURLAsset(url: local)
        } else if let remote = record.audio.flatMap(URL.init(string:)) {
            asset = AVURLAsset(url: remote)
        } else {
            return
        }
        current = record
        duration = 0
        currentTime = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let item = AVPlayerItem(asset: asset)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
        }
        player.replaceCurrentItem(with: item)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlayingElapsed()
    }

    func next() {
        guard let current, let i = queue.firstIndex(of: current), i + 1 < queue.count else {
            isPlaying = false
            return
        }
        load(queue[i + 1])
    }

    func previous() {
        guard let current, let i = queue.firstIndex(of: current), i > 0 else { return }
        load(queue[i - 1])
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingElapsed()
    }

    func skip(_ delta: Double) {
        seek(to: max(0, min(currentTime + delta, duration > 0 ? duration : .greatestFiniteMagnitude)))
    }

    // MARK: - Lock screen / control center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
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
    }

    private func updateNowPlayingInfo() {
        guard let current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPMediaItemPropertyArtist: current.programName,
            MPMediaItemPropertyAlbumTitle: current.language,
        ]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let coverString = current.coverURL, let url = URL(string: coverString) {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
            }
        }
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
