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

    private static func get<T: Decodable>(_ pathAndQuery: String, as type: T.Type) async throws -> APIResponse<T> {
        let url = URL(string: "\(base.absoluteString)/\(pathAndQuery)")!
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
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
}
