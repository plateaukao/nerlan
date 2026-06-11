import Foundation

// MARK: - API envelope

struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let errorcode: Int?
    let message: String?
    let currentPage: Int?
    let totalPage: Int?
    let retData: T?
}

// MARK: - Language / level

struct LanguageCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct LanguageLevel: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
}

// MARK: - Programs

struct Host: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let imgUrl: String?
}

struct Program: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let cover: String?
    let playDate: String?
    let startPlayTime: String?
    let endPlayTime: String?
    let language: String?
    let level: String?
    let hosts: [Host]?

    var coverURL: URL? { cover.flatMap(URL.init(string:)) }

    var scheduleText: String {
        var parts: [String] = []
        if let playDate, !playDate.isEmpty { parts.append(playDate) }
        if let s = startPlayTime, let e = endPlayTime { parts.append("\(s)–\(e)") }
        return parts.joined(separator: " ")
    }
}

/// Program list response groups programs by language.
struct LanguageGroup: Decodable, Identifiable {
    let language: String
    let programs: [Program]
    var id: String { language }
}

struct ProgramInfo: Decodable {
    let id: String
    let name: String
    let introduction: String?
    let cover: String?
    let startPlayTime: String?
    let endPlayTime: String?
    let englishName: String?
    let hosts: [Host]?

    var coverURL: URL? { cover.flatMap(URL.init(string:)) }

    /// Introduction comes back as HTML; strip tags for display.
    var introductionText: String {
        guard let introduction else { return "" }
        return introduction
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Episodes

struct Episode: Decodable, Identifiable, Hashable {
    let id: String
    let programId: String
    let programName: String?
    let title: String?
    let playDate: String?
    let onShelf: Bool?
    let audio: String?

    var audioURL: URL? { audio.flatMap(URL.init(string:)) }
    var displayTitle: String { title ?? "（無標題）" }

    var playDateValue: Date? {
        guard let playDate else { return nil }
        return Episode.dateFormatter.date(from: playDate)
    }

    var playDateText: String {
        guard let d = playDateValue else { return "" }
        return Episode.displayFormatter.string(from: d)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()
}

// MARK: - Local records (favorites & downloads)

/// A self-contained snapshot of an episode plus its program context,
/// so favorites and downloads render without re-fetching the API.
struct EpisodeRecord: Codable, Identifiable, Hashable {
    let id: String          // episode id
    let title: String
    let playDate: String?   // raw API date string
    let audio: String?      // remote stream URL
    let programId: String
    let programName: String
    let language: String
    let coverURL: String?

    init(episode: Episode, programName: String, language: String, coverURL: String?) {
        self.id = episode.id
        self.title = episode.displayTitle
        self.playDate = episode.playDate
        self.audio = episode.audio
        self.programId = episode.programId
        self.programName = programName
        self.language = language
        self.coverURL = coverURL
    }

    var episode: Episode {
        Episode(id: id, programId: programId, programName: programName,
                title: title, playDate: playDate, onShelf: true, audio: audio)
    }
}
