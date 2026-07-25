import CryptoKit
import Foundation

// This file is compiled into BOTH the app and the widget extension — it is the
// only contract between them. The app writes; the widget reads. Nothing here
// may touch Documents, the network, or any app-only singleton.

/// One episode as a widget draws it: a flattened `EpisodeRecord` plus a cover
/// key pointing at a thumbnail the app exported into the shared container.
struct WidgetEpisode: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var programId: String
    var programName: String
    var language: String
    /// Episode length in seconds, when known.
    var duration: Double?
    /// Filename under `covers/`, or nil when the episode has no artwork.
    var coverKey: String?
    var isDownloaded: Bool
    var isPodcast: Bool
}

/// One show — a NER program or a subscribed podcast — for the 我的節目 grid and
/// the configurable 最新單集 widget.
struct WidgetShow: Codable, Hashable, Identifiable {
    var id: String            // programId, or the feed URL for a podcast
    var name: String
    var language: String
    var coverKey: String?
    var isPodcast: Bool
    /// Newest episodes first, at most a handful — what 最新單集 renders.
    var latest: [WidgetEpisode]
}

/// Listening totals for the 學習紀錄 widget. Minutes, not seconds: the widget
/// never shows finer granularity, and coarse values keep the snapshot from
/// changing (and so forcing a reload) on every playback tick.
struct WidgetStats: Codable, Hashable {
    var minutesToday: Int
    var minutesThisWeek: Int
    var streakDays: Int
    var completedCount: Int
}

/// Everything the widgets can draw, published as one small JSON file.
struct WidgetSnapshot: Codable, Hashable {
    var updatedAt: Date
    var nowPlaying: WidgetEpisode?
    var isPlaying: Bool
    /// Playback position within `nowPlaying` as of `positionAt`. The widget
    /// extrapolates from these two while `isPlaying`, so a moving progress bar
    /// costs timeline entries rather than app-driven reloads.
    var position: Double
    var positionAt: Date
    var rate: Double
    /// What follows `nowPlaying` — the rest of the player queue, topped up from
    /// downloads and favorites so the widget is never empty.
    var upNext: [WidgetEpisode]
    var shows: [WidgetShow]
    var stats: WidgetStats

    static let empty = WidgetSnapshot(
        updatedAt: .distantPast, nowPlaying: nil, isPlaying: false,
        position: 0, positionAt: .distantPast, rate: 1,
        upNext: [], shows: [],
        stats: WidgetStats(minutesToday: 0, minutesThisWeek: 0, streakDays: 0, completedCount: 0))

    /// Playback position at `date`, extrapolated while playing. Clamped to the
    /// episode length so a widget left on screen past the end doesn't overrun.
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        let elapsed = max(0, date.timeIntervalSince(positionAt)) * max(rate, 0.1)
        let projected = position + elapsed
        if let duration = nowPlaying?.duration, duration > 0 { return min(projected, duration) }
        return projected
    }

    /// 0…1 progress through `nowPlaying` at `date`, or nil when the length is
    /// unknown (some podcast feeds omit it).
    func progress(at date: Date) -> Double? {
        guard let duration = nowPlaying?.duration, duration > 0 else { return nil }
        return min(1, max(0, position(at: date) / duration))
    }

    /// The episode a bare "play" button should act on: whatever is loaded, else
    /// the first suggestion.
    var leadEpisode: WidgetEpisode? { nowPlaying ?? upNext.first }
}

// MARK: - Shared container

enum WidgetShare {
    /// iOS signs the group as `group.…`; Mac Catalyst requires the team prefix.
    /// Rather than branch on the platform (and hard-code the team in code), probe
    /// both — only one is ever provisioned for a given build.
    private static let groupIdentifiers = [
        "group.com.danielkao.NerLan",
        "3WD42GF27D.group.com.danielkao.NerLan",
    ]

    /// The App Group container, or nil if the entitlement is missing (which is
    /// what every accessor below degrades to: the widget shows its empty state).
    static let containerURL: URL? = {
        for id in groupIdentifiers {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return url
            }
        }
        return nil
    }()

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("widget-snapshot.json")
    }

    static var coversDir: URL? {
        containerURL?.appendingPathComponent("covers", isDirectory: true)
    }

    /// Stable per-URL filename, matching `CoverImageCache`'s scheme: the NER
    /// image endpoint's `key` query is already a unique id; anything else (podcast
    /// art) hashes its URL. Must be deterministic across launches and processes,
    /// so never `String.hashValue`.
    static func coverKey(for urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let key = comps.queryItems?.first(where: { $0.name == "key" })?.value, !key.isEmpty {
            // The key becomes a filename, so anything path-ish has to go.
            let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            return String(safe) + ".jpg"
        }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    static func coverFileURL(_ key: String?) -> URL? {
        guard let key, !key.isEmpty else { return nil }
        return coversDir?.appendingPathComponent(key)
    }

    static func loadSnapshot() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot, returning false when there's no container (unsigned
    /// build, or the entitlement hasn't propagated yet).
    @discardableResult
    static func writeSnapshot(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Widget kinds

enum WidgetKind {
    static let upNext = "NerLanUpNext"
    static let latestEpisode = "NerLanLatestEpisode"
    static let shows = "NerLanShows"
    static let stats = "NerLanStats"
}

// MARK: - Deep links

/// `nerlan://` URLs the widgets hand back to the app. Parsed in `DeepLink.swift`.
enum WidgetLink {
    static let scheme = "nerlan"

    /// Open the app on whatever is playing (full player sheet).
    static var player: URL { URL(string: "\(scheme)://player")! }

    /// Open the app and start (or resume) one episode.
    static func play(episodeId: String) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "play"
        comps.queryItems = [URLQueryItem(name: "id", value: episodeId)]
        return comps.url ?? player
    }

    /// Open a show's episode list.
    static func show(id: String, isPodcast: Bool) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "show"
        comps.queryItems = [URLQueryItem(name: "id", value: id),
                            URLQueryItem(name: "podcast", value: isPodcast ? "1" : "0")]
        return comps.url ?? player
    }

    /// Open one of the app's tabs by name ("programs" / "favorites" / "downloads" / "ai").
    static func tab(_ name: String) -> URL {
        URL(string: "\(scheme)://tab?name=\(name)") ?? player
    }
}
