import AVFoundation
import Combine

/// Records the learner reading a sentence aloud during shadowing practice and
/// plays it back so they can compare with the original. One clip is kept per
/// (episode, sentence); a new attempt overwrites the last. Clips live in Caches
/// (disposable practice data, not synced).
///
/// Recording borrows the audio session from `PlayerManager`, which pauses the
/// original and switches to play-and-record first, then hands it back when the
/// recording stops. Only one of recording / own-voice playback is ever live.
@MainActor
final class ShadowRecorder: NSObject, ObservableObject {
    static let shared = ShadowRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    /// The sentence key most recently recorded, so the UI re-evaluates "play my
    /// voice" availability when a take finishes.
    @Published private(set) var lastRecordedKey: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    /// Set when a stop should auto-play the take; consumed once the file finalizes
    /// (in the recorder delegate), which is the safe moment to read it back.
    private var autoPlayURL: URL?

    private override init() { super.init() }

    /// Caches/shadow/{episodeId}-{index}.m4a.
    private func url(for key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shadow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).m4a")
    }

    func hasRecording(for key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path)
    }

    var permissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    private func requestPermission() async -> Bool {
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Record

    /// Start recording the given sentence. Returns false if mic permission was
    /// denied or the recorder couldn't start (caller surfaces the denial).
    func startRecording(key: String) async -> Bool {
        stopPlayback()
        guard await requestPermission() else { return false }
        PlayerManager.shared.beginRecordingSession()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let target = url(for: key)
        try? FileManager.default.removeItem(at: target)
        guard let rec = try? AVAudioRecorder(url: target, settings: settings) else {
            PlayerManager.shared.endRecordingSession()
            return false
        }
        rec.delegate = self
        recorder = rec
        // record() can fail at the hardware level (mic grabbed elsewhere);
        // reporting "recording" then would wedge the UI and the audio session.
        guard rec.record() else {
            recorder = nil
            PlayerManager.shared.endRecordingSession()
            return false
        }
        isRecording = true
        return true
    }

    /// Stop recording. When `thenPlay` is true the take is played back as soon as
    /// the file finalizes (the shadowing flow plays your voice right after you stop).
    func stopRecording(thenPlay: Bool = false) {
        guard isRecording else { return }
        let recordedURL = recorder?.url
        autoPlayURL = thenPlay ? recordedURL : nil
        // stop() finalizes the file and the delegate fires when it's ready.
        // Keep the reference until then — releasing it here can deallocate the
        // recorder before the callback, silently dropping the auto-play.
        recorder?.stop()
        isRecording = false
        lastRecordedKey = recordedURL?.deletingPathExtension().lastPathComponent
        PlayerManager.shared.endRecordingSession()
    }

    // MARK: - Play back the learner's own voice

    func playRecording(key: String) { play(url(for: key)) }

    private func play(_ target: URL) {
        stopPlayback()
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        PlayerManager.shared.pause()   // don't talk over the original
        guard let p = try? AVAudioPlayer(contentsOf: target) else { return }
        p.delegate = self
        player = p
        p.play()
        isPlaying = true
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// Stop any recording/playback (leaving shadow mode, changing episode, etc.).
    func reset() {
        if isRecording { stopRecording() }
        stopPlayback()
    }
}

extension ShadowRecorder: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder,
                                                     successfully flag: Bool) {
        Task { @MainActor in
            // Release only our own instance — a new take may have started.
            if self.recorder === recorder { self.recorder = nil }
            self.isRecording = false
            if let url = self.autoPlayURL {
                self.autoPlayURL = nil
                if flag { self.play(url) }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
