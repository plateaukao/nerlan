import Foundation

/// Client for 國立教育廣播電台 Channel+ (https://channelplus.ner.gov.tw).
/// Unlike the www.ner.gov.tw LearnLanguage API (current-month episodes only),
/// Channel+ serves the full on-demand archive of every program, with direct
/// MP3 audio. Endpoints discovered from the site's Nuxt bundles and CDP
/// network capture.
enum ChannelPlusAPI {
    static let base = URL(string: "https://channelplus.ner.gov.tw/api/v1")!

    /// Language-learning programs are programType=2.
    static let languageProgramType = 2

    enum APIError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            if case .server(let m) = self { return m }
            return nil
        }
    }

    static func audioURL(_ voiceRef: String?) -> URL? {
        guard let voiceRef, !voiceRef.isEmpty else { return nil }
        return URL(string: "\(base.absoluteString)/audio?key=\(voiceRef)")
    }

    static func imageURL(_ imageRef: String?) -> URL? {
        guard let imageRef, !imageRef.isEmpty else { return nil }
        return URL(string: "\(base.absoluteString)/image?key=\(imageRef)")
    }

    /// Episode attachments (PDF handouts etc.) are served from `file?key=`.
    static func fileURL(_ attachmentKey: String?) -> URL? {
        guard let attachmentKey, !attachmentKey.isEmpty else { return nil }
        return URL(string: "\(base.absoluteString)/file?key=\(attachmentKey)")
    }

    private static func get<T: Decodable>(_ pathAndQuery: String, as type: T.Type) async throws -> APIResponse<T> {
        let url = URL(string: "\(base.absoluteString)/\(pathAndQuery)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The app keeps its own on-disk catalog (`CatalogCache`) and only calls the
        // API on a cache miss or an explicit pull-to-refresh, so these requests must
        // always go to the network. Bypass `URLCache` so a refresh can never return
        // a stale JSON body.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }

    // MARK: - Endpoints

    /// All language-learning programs (currently ~96, single page).
    static func programs() async throws -> [Program] {
        let resp = try await get("programs?page=1&size=500&programType=\(languageProgramType)", as: [Program].self)
        guard resp.success else { throw APIError.server(resp.rtnMsg ?? "programs failed") }
        return resp.data ?? []
    }

    /// One page of a program's episode archive, oldest first
    /// (ascending suits sequential language courses).
    static func episodes(programId: String, page: Int, pageSize: Int = 50)
        async throws -> (episodes: [Episode], totalPages: Int, totalCount: Int)
    {
        let resp = try await get(
            "programs/episodes/\(programId)?page=\(page)&size=\(pageSize)&sortOrder=ASC&sortField=episode_number",
            as: [Episode].self)
        guard resp.success else { throw APIError.server(resp.rtnMsg ?? "episodes failed") }
        return (resp.data ?? [], resp.pagination?.totalPages ?? 1, resp.pagination?.totalCount ?? 0)
    }

    /// The newest episodes of a program, for the 最新單集 widget. The browse list
    /// pages ascending (a course is meant to be taken in order), so its cache
    /// never holds the tail — this asks for the other end explicitly.
    static func latestEpisodes(programId: String, count: Int = 3) async throws -> [Episode] {
        let resp = try await get(
            "programs/episodes/\(programId)?page=1&size=\(count)&sortOrder=DESC&sortField=episode_number",
            as: [Episode].self)
        guard resp.success else { throw APIError.server(resp.rtnMsg ?? "episodes failed") }
        return resp.data ?? []
    }
}

/// Whether the app surfaces the 國立教育廣播電台 catalog at all.
///
/// The radio programs aren't the app's own content, so a fresh install ships as
/// a plain podcast player: no language chips, no program list — only the shows
/// the user adds themselves with +. Pasting any `www.ner.gov.tw` URL into the
/// Add-Podcast sheet reveals the catalog, and it stays revealed from then on.
///
/// Installs that predate this gate keep whatever they already had, via
/// `migrateExistingInstall()`.
enum NERCatalog {
    /// UserDefaults key; also read directly by `ProgramListView`'s `@AppStorage`
    /// so the browse tab reacts the moment the catalog is revealed.
    static let unlockedKey = "nerCatalogUnlocked"

    /// The host a pasted URL has to mention to reveal the catalog. (Deliberately
    /// the public site, not the `channelplus.` API host this client talks to.)
    private static let unlockHost = "www.ner.gov.tw"

    static var isUnlocked: Bool { UserDefaults.standard.bool(forKey: unlockedKey) }

    /// True when pasted text points at the NER site — the reveal gesture rather
    /// than a podcast feed to subscribe to.
    static func isUnlockURL(_ text: String) -> Bool {
        text.lowercased().contains(unlockHost)
    }

    static func unlock() {
        UserDefaults.standard.set(true, forKey: unlockedKey)
    }

    /// Run once at launch: an install from before the gate existed keeps the
    /// catalog it already had, so an update never takes content away. Prior use
    /// is detected from the app's own data files rather than from the stores, so
    /// this can run before anything is loaded.
    static func migrateExistingInstall() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: unlockedKey) == nil else { return }
        defaults.set(hasExistingData, forKey: unlockedKey)
    }

    private static var hasExistingData: Bool {
        if CatalogCache.loadPrograms()?.isEmpty == false { return true }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ["favorites.json", "favorite-programs.json", "downloads.json", "podcasts.json"]
            .contains { fm.fileExists(atPath: docs.appendingPathComponent($0).path) }
    }
}
