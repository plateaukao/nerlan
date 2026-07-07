import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Notified when a streamed file has been received in full and is safe to persist.
protocol CachingPlayerItemDelegate: AnyObject {
    /// The complete file finished downloading into `fileURL` (a temp file).
    /// Always called on the main thread. The receiver takes ownership: move or
    /// copy it; an unclaimed file is deleted by the loader's `invalidate()`.
    func cachingPlayerItem(_ item: CachingPlayerItem, didFinishDownloadingTo fileURL: URL)
}

/// An `AVPlayerItem` that streams a progressive-download file (e.g. an MP3) while
/// buffering every received byte — into a temp *file*, not RAM, so a two-hour
/// podcast doesn't hold ~100 MB of audio in memory — so a fully-played episode
/// can be saved as an offline copy. AVPlayer exposes no API to read its own
/// buffer, so we route the load through an `AVAssetResourceLoaderDelegate`: the
/// asset is built from a URL whose scheme AVPlayer can't play, which forces it
/// to ask *us* for the bytes, and we run the real network request ourselves —
/// feeding the data back to the player and accumulating it at the same time.
///
/// Only the complete, contiguous file is persisted: `cacheDelegate` fires solely
/// when the received byte count matches the server's `Content-Length`, so a
/// paused, failed, or seek-fragmented stream leaves nothing behind. A transient
/// network drop is retried (resumed via a `Range` request) a few times before
/// giving up.
///
/// Caveat: bytes are fetched sequentially from offset 0, so seeking far *ahead*
/// of what has downloaded waits for the sequential fill to reach that point.
/// That suits sequential listening (the common case for a course) and is why the
/// feature is opt-in. For HLS this approach would not work — Channel+ serves a
/// plain file, which is the case this handles.
final class CachingPlayerItem: AVPlayerItem {
    private let loader: ResourceLoaderDelegate
    weak var cacheDelegate: CachingPlayerItemDelegate?

    /// - Parameter url: the real remote audio URL (e.g. https).
    init(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme else {
            fatalError("CachingPlayerItem requires a URL with a scheme")
        }
        // Mask the scheme so AVPlayer can't load it directly and defers to the loader.
        components.scheme = "nerlancache-" + scheme
        let maskedURL = components.url!

        loader = ResourceLoaderDelegate(realURL: url)
        let asset = AVURLAsset(url: maskedURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
        loader.owner = self
    }

    /// Stop downloading and release the network session. Call when this item is no
    /// longer the one playing; an in-flight (incomplete) buffer is discarded.
    func stopDownloading() {
        loader.invalidate()
    }
}

/// Bridges AVPlayer's byte requests to a single sequential `URLSession` download,
/// serving the player while buffering the file for persistence. All resource-loader
/// and URLSession callbacks are delivered on `queue`, so the mutable state below
/// needs no additional locking.
private final class ResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    let queue = DispatchQueue(label: "com.danielkao.nerlan.cachingplayeritem")
    weak var owner: CachingPlayerItem?

    private let realURL: URL
    private var session: URLSession?
    /// The buffered stream on disk. Bytes are appended via `writeHandle` as they
    /// arrive and served back to the player via `readHandle`; `bytesReceived`
    /// tracks the contiguous prefix written so far.
    private let bufferURL: URL
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?
    private var bytesReceived = 0
    /// The buffer file couldn't be created — fail loading requests instead of
    /// letting them hang.
    private var bufferBroken = false
    private var response: URLResponse?
    private var fullContentLength: Int64?
    private var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    private var didStartDownload = false
    private var finished = false
    private var resumeOffset = 0
    private var retryCount = 0
    private let maxRetries = 5
    /// Serve reads in bounded slices so one giant "whole file" request never
    /// materializes the entire buffer as a single Data.
    private static let readSlice = 1 << 20

    init(realURL: URL) {
        self.realURL = realURL
        bufferURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString).tmp")
        super.init()
    }

    func invalidate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.session?.invalidateAndCancel()
            self.session = nil
            try? self.writeHandle?.close()
            try? self.readHandle?.close()
            self.writeHandle = nil
            self.readHandle = nil
            // A finished buffer was handed to (and moved by) the delegate;
            // anything else is an abandoned partial.
            if !self.finished {
                try? FileManager.default.removeItem(at: self.bufferURL)
            }
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if !didStartDownload { startDownload() }
        pendingRequests.insert(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pendingRequests.remove(loadingRequest)
    }

    // MARK: - Download

    private func startDownload() {
        didStartDownload = true
        guard openBuffer() else {
            bufferBroken = true
            processPendingRequests()
            return
        }
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        resumeDownload(from: 0)
    }

    private func openBuffer() -> Bool {
        FileManager.default.createFile(atPath: bufferURL.path, contents: nil)
        writeHandle = try? FileHandle(forWritingTo: bufferURL)
        readHandle = try? FileHandle(forReadingFrom: bufferURL)
        return writeHandle != nil && readHandle != nil
    }

    private func resumeDownload(from offset: Int) {
        guard let session else { return }
        resumeOffset = offset
        var request = URLRequest(url: realURL)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        session.dataTask(with: request).resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        // A 200 means the body starts from byte 0 — either the initial request or a
        // server that ignored our Range header, so reset the buffer to stay contiguous.
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            try? writeHandle?.truncate(atOffset: 0)
            try? writeHandle?.seek(toOffset: 0)
            bytesReceived = 0
        }
        if fullContentLength == nil, response.expectedContentLength > 0 {
            // The initial (unranged) response's length is the whole file.
            fullContentLength = response.expectedContentLength
        }
        processPendingRequests()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try writeHandle?.write(contentsOf: data)
            bytesReceived += data.count
            retryCount = 0
            processPendingRequests()
        } catch {
            // Disk full / handle dead: stop the stream. The item keeps serving
            // what's already buffered; the player then stalls exactly like an
            // unmanaged stream whose connection died.
            session.invalidateAndCancel()
            self.session = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }

        if error == nil, let total = fullContentLength, Int64(bytesReceived) >= total {
            finished = true
            session.finishTasksAndInvalidate()
            self.session = nil
            try? writeHandle?.close()
            writeHandle = nil
            // Hand the buffer file over; the delegate moves it into the cache.
            // Moving under our open read handle is fine — the descriptor keeps
            // the inode, so serving the player continues uninterrupted.
            let fileURL = bufferURL
            DispatchQueue.main.async { [weak owner] in
                guard let owner, let delegate = owner.cacheDelegate else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                delegate.cachingPlayerItem(owner, didFinishDownloadingTo: fileURL)
            }
            return
        }

        // Incomplete: retry from where we stopped, with a cap. Beyond that, give up
        // and persist nothing — playback may stall just as an unmanaged stream would.
        if let total = fullContentLength, Int64(bytesReceived) < total, retryCount < maxRetries {
            retryCount += 1
            resumeDownload(from: bytesReceived)
        } else {
            session.invalidateAndCancel()
            self.session = nil
        }
    }

    // MARK: - Serving the player

    private func processPendingRequests() {
        if bufferBroken {
            // No buffer file — surface an error rather than hanging the player.
            for request in pendingRequests {
                request.finishLoading(with: URLError(.cannotCreateFile))
            }
            pendingRequests.removeAll()
            return
        }
        let completed = pendingRequests.filter { request in
            fillInContentInformation(request.contentInformationRequest)
            if let dataRequest = request.dataRequest {
                let done = respond(to: dataRequest)
                if done { request.finishLoading() }
                return done
            }
            // Content-information-only request: done as soon as we have the response.
            if response != nil { request.finishLoading(); return true }
            return false
        }
        pendingRequests.subtract(completed)
    }

    private func fillInContentInformation(_ infoRequest: AVAssetResourceLoadingContentInformationRequest?) {
        guard let infoRequest, let response else { return }
        if let mime = response.mimeType, let type = UTType(mimeType: mime) {
            infoRequest.contentType = type.identifier
        } else {
            infoRequest.contentType = UTType.mp3.identifier
        }
        if let length = fullContentLength, length > 0 {
            infoRequest.contentLength = length
        }
        infoRequest.isByteRangeAccessSupported = true
    }

    /// Feed whatever contiguous bytes we already have toward this request, in
    /// bounded slices read back from the buffer file. Returns true once the
    /// request's full requested range has been satisfied.
    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        guard let readHandle else { return false }
        while true {
            // Computed by subtraction so a "whole rest of the file" request
            // (huge requestedLength) can't overflow the addition.
            let served = Int(dataRequest.currentOffset - dataRequest.requestedOffset)
            let remaining = dataRequest.requestedLength - served
            if remaining <= 0 { return true }
            let currentOffset = Int(dataRequest.currentOffset)
            let available = bytesReceived - currentOffset
            if available <= 0 { return false }
            let count = min(available, remaining, Self.readSlice)
            guard (try? readHandle.seek(toOffset: UInt64(currentOffset))) != nil,
                  let chunk = try? readHandle.read(upToCount: count), !chunk.isEmpty else { return false }
            dataRequest.respond(with: chunk)
        }
    }
}
