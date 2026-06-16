import Foundation

/// Stateless helper (mirroring `ChannelPlusAPI`) for turning a pasted podcast
/// URL into an RSS feed URL, and fetching feed bytes. Three input shapes:
///   - an Apple Podcasts page (`podcasts.apple.com/.../idNNN`) — resolved to its
///     RSS `feedUrl` via the public iTunes Lookup API,
///   - an `apple.co` short link — its redirect is followed first,
///   - anything else — treated as a raw RSS feed URL.
enum PodcastAPI {
    enum APIError: LocalizedError {
        case notAPodcast
        case server(String)
        var errorDescription: String? {
            switch self {
            case .notAPodcast: return "找不到對應的 Podcast"
            case .server(let m): return m
            }
        }
    }

    /// Some feed hosts (and Apple) reject requests without a browser-ish UA.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) NerLan/1.0"

    /// Resolve a pasted URL to an RSS feed URL.
    static func resolveFeedURL(from pasted: URL) async throws -> URL {
        var url = pasted
        // apple.co share links redirect to the real podcasts.apple.com page.
        if (url.host ?? "").contains("apple.co") {
            url = try await resolveRedirect(url)
        }
        if (url.host ?? "").contains("apple.com"), let collectionId = appleCollectionId(from: url) {
            return try await feedURL(forCollectionId: collectionId)
        }
        // Raw RSS / direct feed URL — use as-is.
        return url
    }

    /// Download a feed (or any) URL's bytes with a browser-ish UA.
    static func fetchFeedData(_ url: URL) async throws -> Data {
        let (data, response) = try await get(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.server("下載 RSS 失敗（HTTP \(http.statusCode)）")
        }
        return data
    }

    // MARK: - Apple Podcasts resolution

    /// The numeric collection id from an Apple Podcasts URL (".../idNNN"),
    /// ignoring any trailing `?i=` episode parameter and country prefix.
    private static func appleCollectionId(from url: URL) -> String? {
        let s = url.absoluteString
        guard let range = s.range(of: #"/id(\d+)"#, options: .regularExpression) else { return nil }
        return String(s[range].dropFirst(3))   // drop "/id"
    }

    /// iTunes Lookup → the show's RSS `feedUrl`.
    private static func feedURL(forCollectionId id: String) async throws -> URL {
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "entity", value: "podcast"),
        ]
        let (data, _) = try await get(comps.url!)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let feed = results.first?["feedUrl"] as? String,
              let feedURL = URL(string: feed) else {
            throw APIError.notAPodcast
        }
        return feedURL
    }

    /// Follow redirects to where a short link lands (URLSession follows them by
    /// default; the final URL is on the response).
    private static func resolveRedirect(_ url: URL) async throws -> URL {
        let (_, response) = try await get(url)
        return response.url ?? url
    }

    private static func get(_ url: URL) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return try await URLSession.shared.data(for: req)
    }
}
