import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Notified when a streamed file has been received in full and is safe to persist.
protocol CachingPlayerItemDelegate: AnyObject {
    /// The complete file finished downloading. Always called on the main thread.
    func cachingPlayerItem(_ item: CachingPlayerItem, didFinishDownloading data: Data)
}

/// An `AVPlayerItem` that streams a progressive-download file (e.g. an MP3) while
/// buffering every received byte, so a fully-played episode can be saved as an
/// offline copy. AVPlayer exposes no API to read its own buffer, so we route the
/// load through an `AVAssetResourceLoaderDelegate`: the asset is built from a URL
/// whose scheme AVPlayer can't play, which forces it to ask *us* for the bytes,
/// and we run the real network request ourselves — feeding the data back to the
/// player and accumulating it at the same time.
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
    private var mediaData = Data()
    private var response: URLResponse?
    private var fullContentLength: Int64?
    private var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    private var didStartDownload = false
    private var finished = false
    private var resumeOffset = 0
    private var retryCount = 0
    private let maxRetries = 5

    init(realURL: URL) {
        self.realURL = realURL
        super.init()
    }

    func invalidate() {
        queue.async { [weak self] in
            self?.session?.invalidateAndCancel()
            self?.session = nil
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
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: opQueue)
        resumeDownload(from: 0)
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
            mediaData.removeAll(keepingCapacity: true)
        }
        if fullContentLength == nil, response.expectedContentLength > 0 {
            // The initial (unranged) response's length is the whole file.
            fullContentLength = response.expectedContentLength
        }
        processPendingRequests()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        mediaData.append(data)
        retryCount = 0
        processPendingRequests()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }

        if error == nil, let total = fullContentLength, Int64(mediaData.count) >= total {
            finished = true
            let data = mediaData
            session.finishTasksAndInvalidate()
            self.session = nil
            DispatchQueue.main.async { [weak owner] in
                guard let owner else { return }
                owner.cacheDelegate?.cachingPlayerItem(owner, didFinishDownloading: data)
            }
            return
        }

        // Incomplete: retry from where we stopped, with a cap. Beyond that, give up
        // and persist nothing — playback may stall just as an unmanaged stream would.
        if let total = fullContentLength, Int64(mediaData.count) < total, retryCount < maxRetries {
            retryCount += 1
            resumeDownload(from: mediaData.count)
        } else {
            session.invalidateAndCancel()
            self.session = nil
        }
    }

    // MARK: - Serving the player

    private func processPendingRequests() {
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

    /// Feed whatever contiguous bytes we already have toward this request. Returns
    /// true once the request's full requested range has been satisfied.
    private func respond(to dataRequest: AVAssetResourceLoadingDataRequest) -> Bool {
        let currentOffset = Int(dataRequest.currentOffset)
        guard mediaData.count > currentOffset else { return false }

        let bytesToRespond = min(mediaData.count - currentOffset, dataRequest.requestedLength)
        dataRequest.respond(with: mediaData.subdata(in: currentOffset ..< currentOffset + bytesToRespond))

        return mediaData.count >= Int(dataRequest.requestedOffset) + dataRequest.requestedLength
    }
}
