import CryptoKit
import ImageIO
import UIKit

/// Two-tier cover-image cache: an in-memory `NSCache` for the running session and
/// a persistent on-disk copy in Caches. A fetched cover is written to storage and
/// reused on every later access — including across app launches — so it is only
/// re-downloaded if the file is missing (first run, or the OS purged Caches).
///
/// This replaces relying on `URLCache`/`AsyncImage`: the image endpoint sends no
/// `Cache-Control` (only `ETag`/`Last-Modified`), so `URLCache` revalidates the
/// cover on every cold launch — an effective re-fetch. An explicit store avoids
/// that entirely.
final class CoverImageCache {
    static let shared = CoverImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let lock = NSLock()
    /// In-flight fetches, so many rows sharing one program cover trigger a single
    /// download rather than one per row.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Largest rendered cover is the 240pt full-player art; at 3× that's 720px.
    /// Decoding straight to this bound keeps a 3000×3000 podcast original from
    /// occupying ~34 MB of decoded bitmap to draw a 44pt row thumbnail.
    private static let maxPixelSize = 720

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.totalCostLimit = 64 * 1024 * 1024   // ~64 MB of decoded covers
    }

    /// Decode at most `maxPixelSize` on the long edge, without ever inflating
    /// the full-resolution bitmap (ImageIO thumbnailing decodes at target size).
    private static func decodeDownsampled(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Store in the memory cache with its decoded-bitmap size as the cost, so
    /// `totalCostLimit` evicts by actual memory footprint.
    private func remember(_ image: UIImage, key k: String) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: k as NSString, cost: cost)
    }

    /// Stable filename for a cover URL. The image endpoint's `key` query is a
    /// unique id; fall back to a hash of the whole URL for anything else (e.g.
    /// podcast cover art, whose URLs carry no `key`).
    ///
    /// The fallback must be a *stable* hash: `String.hashValue` is seeded per
    /// process, so it returns a different value every launch — which renamed each
    /// podcast cover's cache file on every launch, so the file was never found and
    /// the cover re-downloaded (and orphaned a new file) every time. SHA-256 is
    /// deterministic, so the on-disk cache actually persists.
    private func key(for url: URL) -> String {
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let k = comps.queryItems?.first(where: { $0.name == "key" })?.value, !k.isEmpty {
            return k
        }
        return SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Synchronous memory-only lookup, for instant first paint without a hop.
    func memoryCached(_ url: URL) -> UIImage? {
        memory.object(forKey: key(for: url) as NSString)
    }

    /// Returns the image from memory, then disk, then the network (storing to both
    /// on a network hit). Concurrent calls for the same URL share one fetch.
    func image(for url: URL) async -> UIImage? {
        let k = key(for: url)
        if let img = memory.object(forKey: k as NSString) { return img }

        lock.lock()
        if let existing = inFlight[k] {
            lock.unlock()
            return await existing.value
        }
        let task = Task { await self.fetch(url, key: k) }
        inFlight[k] = task
        lock.unlock()

        let result = await task.value
        lock.lock(); inFlight[k] = nil; lock.unlock()
        return result
    }

    private func fetch(_ url: URL, key k: String) async -> UIImage? {
        let file = dir.appendingPathComponent(k)
        if let data = try? Data(contentsOf: file), let img = Self.decodeDownsampled(data) {
            remember(img, key: k)
            return img
        }
        // Bypass `URLCache` — this cache is the durable store.
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let img = Self.decodeDownsampled(data) else { return nil }
        remember(img, key: k)
        // Disk keeps the original bytes — re-decode picks the size it needs.
        try? data.write(to: file)
        return img
    }
}
