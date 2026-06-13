import Combine
import Foundation

/// Downloads episode MP3s for offline playback. Channel+ serves direct
/// audio files, so this is a plain URLSession background download into
/// Documents/audio/{episodeId}.mp3.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [EpisodeRecord] = []
    /// episodeId -> 0...1 while an episode's audio download is in flight
    @Published private(set) var progress: [String: Double] = [:]

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

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordsURL = docs.appendingPathComponent("downloads.json")
        audioDir = docs.appendingPathComponent("audio", isDirectory: true)
        attachmentsDir = docs.appendingPathComponent("attachments", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)

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
        progress[episodeId] != nil
    }

    func localAssetURL(episodeId: String) -> URL? {
        let url = fileURL(episodeId: episodeId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
            progress[record.id] = 0
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
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard case .audio(let record) = tasks[downloadTask.taskIdentifier],
              totalBytesExpectedToWrite > 0 else { return }
        progress[record.id] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let target = tasks[downloadTask.taskIdentifier] else { return }
        switch target {
        case .audio(let record):
            let dest = fileURL(episodeId: record.id)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
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
            progress.removeValue(forKey: record.id)
        }
    }
}
