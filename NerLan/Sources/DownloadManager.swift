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

        let config = URLSessionConfiguration.background(withIdentifier: "com.danielkao.nerlan.downloads")
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    private func fileURL(episodeId: String) -> URL {
        audioDir.appendingPathComponent("\(episodeId).mp3")
    }

    private func attachmentFileURL(_ attachment: Attachment) -> URL {
        attachmentsDir.appendingPathComponent("\(attachment.attachmentKey).\(attachment.fileExtension)")
    }

    func isDownloaded(episodeId: String) -> Bool {
        localAssetURL(episodeId: episodeId) != nil
    }

    func isDownloading(episodeId: String) -> Bool {
        downloading.contains(episodeId)
    }

    func localAssetURL(episodeId: String) -> URL? {
        let url = fileURL(episodeId: episodeId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Streamed-audio cache

    private func cacheFileURL(episodeId: String) -> URL {
        cacheDir.appendingPathComponent("\(episodeId).mp3")
    }

    /// A copy captured while streaming, if one exists. Used by the player after an
    /// explicit download but before falling back to the network.
    func cachedAssetURL(episodeId: String) -> URL? {
        let url = cacheFileURL(episodeId: episodeId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Persist a fully-streamed episode. No-op if it's already an explicit
    /// download (that copy takes precedence and shouldn't be duplicated).
    func storeCachedAudio(_ data: Data, episodeId: String) {
        guard !isDownloaded(episodeId: episodeId) else { return }
        try? data.write(to: cacheFileURL(episodeId: episodeId), options: .atomic)
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
            tasks[task.taskIdentifier] = .attachment(attachment)
            task.resume()
        }
    }

    func delete(episodeId: String) {
        try? FileManager.default.removeItem(at: fileURL(episodeId: episodeId))
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
        guard let target = tasks[downloadTask.taskIdentifier] else { return }
        switch target {
        case .audio(let record):
            let dest = fileURL(episodeId: record.id)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                // An explicit download supersedes any streamed-cache copy.
                try? FileManager.default.removeItem(at: cacheFileURL(episodeId: record.id))
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
        guard let target = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        if case .audio(let record) = target {
            downloading.remove(record.id)
        }
    }
}
