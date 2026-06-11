import Combine
import Foundation

/// Downloads episode MP3s for offline playback. Channel+ serves direct
/// audio files, so this is a plain URLSession background download into
/// Documents/audio/{episodeId}.mp3.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [EpisodeRecord] = []
    /// episodeId -> 0...1 while a download is in flight
    @Published private(set) var progress: [String: Double] = [:]

    private var session: URLSession!
    private var taskEpisode: [Int: EpisodeRecord] = [:]   // taskIdentifier -> record

    private let recordsURL: URL
    private let audioDir: URL

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordsURL = docs.appendingPathComponent("downloads.json")
        audioDir = docs.appendingPathComponent("audio", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

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

    func download(_ record: EpisodeRecord) {
        guard !isDownloaded(episodeId: record.id), !isDownloading(episodeId: record.id),
              let remote = record.audio.flatMap(URL.init(string:)) else { return }
        let task = session.downloadTask(with: remote)
        taskEpisode[task.taskIdentifier] = record
        progress[record.id] = 0
        task.resume()
    }

    func delete(episodeId: String) {
        try? FileManager.default.removeItem(at: fileURL(episodeId: episodeId))
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
        guard let record = taskEpisode[downloadTask.taskIdentifier],
              totalBytesExpectedToWrite > 0 else { return }
        progress[record.id] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let record = taskEpisode[downloadTask.taskIdentifier] else { return }
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
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let record = taskEpisode.removeValue(forKey: task.taskIdentifier) else { return }
        progress.removeValue(forKey: record.id)
    }
}
