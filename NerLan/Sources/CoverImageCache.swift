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

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Stable filename for a cover URL. The image endpoint's `key` query is a
    /// unique id; fall back to a hash of the whole URL for anything else.
    private func key(for url: URL) -> String {
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let k = comps.queryItems?.first(where: { $0.name == "key" })?.value, !k.isEmpty {
            return k
        }
        return String(UInt(bitPattern: url.absoluteString.hashValue))
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
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: k as NSString)
            return img
        }
        // Bypass `URLCache` — this cache is the durable store.
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: k as NSString)
        try? data.write(to: file)
        return img
    }
}
