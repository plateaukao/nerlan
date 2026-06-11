import Foundation

/// Client for 國立教育廣播電台 (National Education Radio) language-learning API.
/// Endpoints discovered from https://www.ner.gov.tw/LearnLanguage/ frontend bundles.
enum NERAPI {
    static let base = URL(string: "https://webapi.ner.gov.tw/nerwebFront")!

    enum APIError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            if case .server(let m) = self { return m }
            return nil
        }
    }

    private static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> APIResponse<T> {
        let url = base.appendingPathComponent(path)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // appendingPathComponent percent-encodes "?", so build query separately
        if let qIndex = path.firstIndex(of: "?") {
            comps = URLComponents(url: base.appendingPathComponent(String(path[..<qIndex])), resolvingAgainstBaseURL: false)!
            comps.query = String(path[path.index(after: qIndex)...])
        }
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }

    /// The server ignores JSON bodies; the site's axios wrapper sends multipart/form-data.
    private static func post<T: Decodable>(_ path: String, fields: [String: String], as type: T.Type) async throws -> APIResponse<T> {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        let boundary = "NerLanBoundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(APIResponse<T>.self, from: data)
    }

    // MARK: - Endpoints

    static func languageCategories() async throws -> [LanguageCategory] {
        let resp = try await get("api/LanguageProgram/GetLanguageCategory", as: [LanguageCategory].self)
        guard resp.success else { throw APIError.server(resp.message ?? "GetLanguageCategory failed") }
        return resp.retData ?? []
    }

    static func languageLevels() async throws -> [LanguageLevel] {
        let resp = try await get("api/LanguageProgram/GetLanguageLevel", as: [LanguageLevel].self)
        guard resp.success else { throw APIError.server(resp.message ?? "GetLanguageLevel failed") }
        return resp.retData ?? []
    }

    /// Returns programs grouped by language. The default pagesize covers the
    /// whole catalog (~68 programs) in one request.
    static func programList(keywords: String = "", languageId: String = "",
                            levelId: String = "", page: Int = 1, pageSize: Int = 200)
        async throws -> [LanguageGroup]
    {
        let resp = try await post("api/LanguageProgram/GetLanguageProgramList",
                                  fields: ["keyWords": keywords, "languageId": languageId,
                                           "levelId": levelId, "pageindex": String(page),
                                           "pagesize": String(pageSize)],
                                  as: [LanguageGroup].self)
        guard resp.success else { throw APIError.server(resp.message ?? "GetLanguageProgramList failed") }
        return resp.retData ?? []
    }

    static func programInfo(id: String) async throws -> ProgramInfo {
        let resp = try await get("api/LanguageEpisode/GetLanguageProgramInfo?languageProgramId=\(id)", as: ProgramInfo.self)
        guard resp.success, let info = resp.retData else {
            throw APIError.server(resp.message ?? "GetLanguageProgramInfo failed")
        }
        return info
    }

    /// Episodes are published per calendar month; pagesize must cover the number of days.
    static func episodes(programId: String, year: Int, month: Int) async throws -> [Episode] {
        let days = Calendar.current.range(of: .day, in: .month,
                                          for: DateComponents(calendar: .current, year: year, month: month).date!)?.count ?? 31
        let resp = try await get(
            "api/LanguageEpisode/GetLanguageEpisodeList?languageProgramId=\(programId)&year=\(year)&month=\(month)&pagesize=\(days)",
            as: [Episode].self)
        guard resp.success else { throw APIError.server(resp.message ?? "GetLanguageEpisodeList failed") }
        return (resp.retData ?? []).sorted {
            ($0.playDateValue ?? .distantPast) < ($1.playDateValue ?? .distantPast)
        }
    }
}
