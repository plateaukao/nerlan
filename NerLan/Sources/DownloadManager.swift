import AVFoundation
import Combine
import Foundation

/// Downloads episodes for offline playback. NER serves audio as HLS (m3u8),
/// so downloads go through AVAssetDownloadURLSession, which packages the
/// stream into a movie bundle that AVPlayer can play offline.
/// Note: AVAssetDownloadURLSession requires a real device; the simulator
/// does not support HLS asset downloads.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var records: [EpisodeRecord] = []
    /// episodeId -> 0...1 while a download is in flight
    @Published private(set) var progress: [String: Double] = [:]

    private var session: AVAssetDownloadURLSession!
    private var taskEpisode: [Int: EpisodeRecord] = [:]   // taskIdentifier -> record
    private var pendingLocations: [Int: URL] = [:]        // set in didFinishDownloadingTo, committed on completion

    private let recordsURL: URL
    private let locationsURL: URL
    private var locations: [String: String] = [:]         // episodeId -> path relative to home

    override private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recordsURL = docs.appendingPathComponent("downloads.json")
        locationsURL = docs.appendingPathComponent("download-locations.json")
        super.init()

        if let data = try? Data(contentsOf: recordsURL),
           let saved = try? JSONDecoder().decode([EpisodeRecord].self, from: data) {
            records = saved
        }
        if let data = try? Data(contentsOf: locationsURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            locations = saved
        }

        let config = URLSessionConfiguration.background(withIdentifier: "com.danielkao.nerlan.downloads")
        session = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }

    func isDownloaded(episodeId: String) -> Bool {
        localAssetURL(episodeId: episodeId) != nil
    }

    func isDownloading(episodeId: String) -> Bool {
        progress[episodeId] != nil
    }

    func localAssetURL(episodeId: String) -> URL? {
        guard let rel = locations[episodeId] else { return nil }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ record: EpisodeRecord) {
        guard !isDownloaded(episodeId: record.id), !isDownloading(episodeId: record.id),
              let remote = record.audio.flatMap(URL.init(string:)) else { return }
        let asset = AVURLAsset(url: remote)
        guard let task = session.makeAssetDownloadTask(
            asset: asset, assetTitle: record.title, assetArtworkData: nil) else { return }
        taskEpisode[task.taskIdentifier] = record
        progress[record.id] = 0
        task.resume()
    }

    func delete(episodeId: String) {
        if let rel = locations[episodeId] {
            let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel)
            try? FileManager.default.removeItem(at: url)
            locations.removeValue(forKey: episodeId)
        }
        records.removeAll { $0.id == episodeId }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(records).write(to: recordsURL)
        try? JSONEncoder().encode(locations).write(to: locationsURL)
    }
}

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let record = taskEpisode[assetDownloadTask.taskIdentifier] else { return }
        let loaded = totalTimeRangesLoaded.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let expected = timeRangeExpectedToLoad.duration.seconds
        if expected > 0 { progress[record.id] = min(loaded / expected, 1.0) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        pendingLocations[assetDownloadTask.taskIdentifier] = location
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let record = taskEpisode.removeValue(forKey: task.taskIdentifier) else { return }
        let location = pendingLocations.removeValue(forKey: task.taskIdentifier)
        progress.removeValue(forKey: record.id)

        guard error == nil, let location else {
            // Failed or cancelled: discard any partial download.
            if let location { try? FileManager.default.removeItem(at: location) }
            return
        }
        // location is relative to the home directory and only valid as a relative path across launches
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var rel = location.standardizedFileURL.path
        if rel.hasPrefix(home) { rel = String(rel.dropFirst(home.count + 1)) }
        locations[record.id] = rel
        if !records.contains(where: { $0.id == record.id }) {
            records.append(record)
        }
        persist()
    }
}
