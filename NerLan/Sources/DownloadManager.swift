import Combine
import Foundation

/// Downloads episode MP3s for offline playback. Channel+ serves direct
/// audio files, so this is a plain URLSession background download into
/// Documents/audio/{episodeId}.mp3.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [EpisodeRecord] = []
    /// Episode ids whose audio download is in flight. Membership only — the UI
    /// shows an indeterminate spinner, so there's no per-byte progress to publish
    /// (republishing a fraction on every chunk pegged the main thread and got the
    /// app killed for exceeding the background CPU limit).
    @Published private(set) var downloading: Set<String> = []
    /// Episode ids with a downloaded audio file, mirroring `audioDir` — so
    /// `isDownloaded` (hit by every episode row on every render) is a set
    /// lookup instead of up to 7 `fileExists` stats on the main thread.
    @Published private(set) var downloadedIds: Set<String> = []

    /// What a background download task is fetching: an episode's audio, or one
    /// of its attachments. Attachments piggyback on the audio download so they
    /// are available offline alongside it.
    private enum TaskTarget {
        case audio(EpisodeRecord)
        case attachment(Attachment)
    }

    private var session: URLSession!
    private var tasks: [Int: TaskTarget] = [:]   // taskIdentifier -> target

    private let recordsURL: URL
    private let audioDir: URL
    private let attachmentsDir: URL
    /// Audio captured while streaming (opt-in). Kept separate from explicit
    /// downloads: it lives in Caches (purgeable, not iCloud-backed), never shows
    /// in the Downloads tab, and is wiped as a unit by "clear cached audio".
    private let cacheDir: URL

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        recordsURL = docs.appendingPathComponent("downloads.json")
        audioDir = docs.appendingPathComponent("audio", isDirectory: true)
        attachmentsDir = docs.appendingPathComponent("attachments", isDirectory: true)
        cacheDir = caches.appendingPathComponent("audio", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: recordsURL),
           let saved = try? JSONDecoder().decode([EpisodeRecord].self, from: data) {
            records = saved
        }
        let audioFiles = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)) ?? []
        downloadedIds = Set(audioFiles.map { $0.deletingPathExtension().lastPathComponent })

        let config = URLSessionConfiguration.background(withIdentifier: "com.danielkao.nerlan.downloads")
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        // Reconnect to downloads still running from a previous launch: the
        // background session survives the process, but the in-memory task map
        // doesn't — rebuild it (and the spinners) from each task's description.
        session.getAllTasks { [weak self] running in
            guard let self else { return }
            for task in running {
                guard self.tasks[task.taskIdentifier] == nil,
                      let target = Self.target(fromDescription: task.taskDescription) else { continue }
                self.tasks[task.taskIdentifier] = target
                if case .audio(let record) = target { self.downloading.insert(record.id) }
            }
        }
    }

    /// Called by the app delegate when the system relaunches the app to deliver
    /// background-download events; invoked once the session has delivered them.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Task target persistence

    // The taskIdentifier -> TaskTarget map only lives in memory, but background
    // downloads outlive the process. Each task carries its target in
    // `taskDescription` (a string the system persists with the task), so a
    // download that finishes after a relaunch can still be filed correctly
    // instead of being silently discarded.

    private static func taskDescription(for target: TaskTarget) -> String? {
        switch target {
        case .audio(let record):
            return (try? JSONEncoder().encode(record)).map { "audio:" + $0.base64EncodedString() }
        case .attachment(let attachment):
            return (try? JSONEncoder().encode(attachment)).map { "attachment:" + $0.base64EncodedString() }
        }
    }

    private static func target(fromDescription desc: String?) -> TaskTarget? {
        guard let desc else { return nil }
        if desc.hasPrefix("audio:"),
           let data = Data(base64Encoded: String(desc.dropFirst("audio:".count))),
           let record = try? JSONDecoder().decode(EpisodeRecord.self, from: data) {
            return .audio(record)
        }
        if desc.hasPrefix("attachment:"),
           let data = Data(base64Encoded: String(desc.dropFirst("attachment:".count))),
           let attachment = try? JSONDecoder().decode(Attachment.self, from: data) {
            return .attachment(attachment)
        }
        return nil
    }

    /// Audio file extensions an episode might be stored under: NER is always mp3,
    /// podcasts can be m4a/aac/etc. Probed in order, so the mp3 common case hits
    /// first and NER rows incur a single `fileExists` stat (no regression).
    private static let audioExtensions = ["mp3", "m4a", "aac", "ogg", "opus", "wav", "mp4"]

    /// Where an episode's audio is stored, using its declared extension. A
    /// real-m4a file stored under a .mp3 name can fail to play, so podcasts keep
    /// their true extension.
    private func audioFileURL(for record: EpisodeRecord) -> URL {
        audioDir.appendingPathComponent("\(record.id).\(record.audioFileExtension)")
    }

    private func attachmentFileURL(_ attachment: Attachment) -> URL {
        attachmentsDir.appendingPathComponent("\(attachment.attachmentKey).\(attachment.fileExtension)")
    }

    func isDownloaded(episodeId: String) -> Bool {
        downloadedIds.contains(episodeId)
    }

    func isDownloading(episodeId: String) -> Bool {
        downloading.contains(episodeId)
    }

    /// The downloaded audio file for an id, whatever extension it was saved with.
    func localAssetURL(episodeId: String) -> URL? {
        Self.existingFile(in: audioDir, id: episodeId)
    }

    private static func existingFile(in dir: URL, id: String) -> URL? {
        for ext in audioExtensions {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: - Streamed-audio cache

    /// A copy captured while streaming, if one exists. Used by the player after an
    /// explicit download but before falling back to the network.
    func cachedAssetURL(episodeId: String) -> URL? {
        Self.existingFile(in: cacheDir, id: episodeId)
    }

    /// Persist a fully-streamed episode under its real extension (so AAC plays
    /// back correctly). No-op if it's already an explicit download (that copy
    /// takes precedence and shouldn't be duplicated).
    func storeCachedAudio(_ data: Data, episodeId: String, ext: String = "mp3") {
        guard !isDownloaded(episodeId: episodeId) else { return }
        try? data.write(to: cacheDir.appendingPathComponent("\(episodeId).\(ext)"), options: .atomic)
    }

    func clearAudioCache() {
        let items = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        for item in items { try? FileManager.default.removeItem(at: item) }
    }

    func cachedAudioByteSize() -> Int64 { Self.directoryByteSize(cacheDir) }

    // MARK: - Inventory (for the 資料統計 screen)

    /// Number of explicitly downloaded episodes.
    var downloadedEpisodeCount: Int { records.count }

    func downloadedAudioByteSize() -> Int64 { Self.directoryByteSize(audioDir) }

    func attachmentCount() -> Int { Self.fileCount(attachmentsDir) }

    /// Number of episodes captured by the streamed-audio cache.
    func cachedEpisodeCount() -> Int { Self.fileCount(cacheDir) }

    private static func directoryByteSize(_ dir: URL) -> Int64 {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return items.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func fileCount(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.count ?? 0
    }

    /// Local copy of an attachment, if it has been downloaded.
    func localAttachmentURL(_ attachment: Attachment) -> URL? {
        let url = attachmentFileURL(attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ record: EpisodeRecord) {
        if !isDownloaded(episodeId: record.id), !isDownloading(episodeId: record.id),
           let remote = record.audio.flatMap(URL.init(string:)) {
            let task = session.downloadTask(with: remote)
            task.taskDescription = Self.taskDescription(for: .audio(record))
            tasks[task.taskIdentifier] = .audio(record)
            downloading.insert(record.id)
            task.resume()
        }
        downloadAttachments(for: record)
    }

    /// Fetch any not-yet-saved attachments for an episode (no progress UI —
    /// they're small handouts that ride along with the audio download).
    private func downloadAttachments(for record: EpisodeRecord) {
        for attachment in record.attachments ?? [] {
            guard localAttachmentURL(attachment) == nil,
                  !tasks.values.contains(where: { if case .attachment(let a) = $0 { return a.id == attachment.id } else { return false } }),
                  let url = attachment.remoteURL else { continue }
            let task = session.downloadTask(with: url)
            task.taskDescription = Self.taskDescription(for: .attachment(attachment))
            tasks[task.taskIdentifier] = .attachment(attachment)
            task.resume()
        }
    }

    func delete(episodeId: String) {
        if let url = localAssetURL(episodeId: episodeId) {
            try? FileManager.default.removeItem(at: url)
        }
        downloadedIds.remove(episodeId)
        if let record = records.first(where: { $0.id == episodeId }) {
            for attachment in record.attachments ?? [] {
                try? FileManager.default.removeItem(at: attachmentFileURL(attachment))
            }
        }
        records.removeAll { $0.id == episodeId }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(records).write(to: recordsURL)
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    // No didWriteData: progress is membership-only (an indeterminate spinner), so
    // there's deliberately nothing to publish per byte-chunk.

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The map covers tasks started this launch; the description covers tasks
        // that finished after the app was relaunched.
        guard let target = tasks[downloadTask.taskIdentifier]
            ?? Self.target(fromDescription: downloadTask.taskDescription) else { return }
        switch target {
        case .audio(let record):
            let dest = audioFileURL(for: record)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                downloadedIds.insert(record.id)
                // An explicit download supersedes any streamed-cache copy.
                if let cached = cachedAssetURL(episodeId: record.id) {
                    try? FileManager.default.removeItem(at: cached)
                }
                if !records.contains(where: { $0.id == record.id }) {
                    records.append(record)
                }
                persist()
            } catch {
                // moving failed; leave no record so the user can retry
            }
        case .attachment(let attachment):
            let dest = attachmentFileURL(attachment)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: location, to: dest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let target = tasks.removeValue(forKey: task.taskIdentifier)
            ?? Self.target(fromDescription: task.taskDescription) else { return }
        if case .audio(let record) = target {
            downloading.remove(record.id)
        }
    }

    /// All queued background events have been delivered — tell the system so it
    /// can take the relaunch's snapshot / suspend the app again.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
