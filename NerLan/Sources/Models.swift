import Foundation

// MARK: - API envelope (Channel+)

struct APIResponse<T: Decodable>: Decodable {
    let rtnCode: String
    let rtnMsg: String?
    let data: T?
    let pagination: Pagination?

    var success: Bool { rtnCode == "0000" }
}

struct Pagination: Decodable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalCount: Int
}

// MARK: - Shared fragments

struct Tag: Codable, Identifiable, Hashable {
    let tagId: String
    let name: String
    var id: String { tagId }
}

struct ImageRef: Codable, Hashable {
    let imageRef: String?
}

struct VoiceRef: Codable, Hashable {
    let voiceRef: String?
}

/// A downloadable file attached to an episode — typically a PDF handout (講義).
struct Attachment: Codable, Identifiable, Hashable {
    let originalName: String?
    let fileType: String?
    let attachmentKey: String

    var id: String { attachmentKey }
    var displayName: String { originalName ?? "附件" }

    /// File extension to store/open the attachment with (defaults to pdf).
    var fileExtension: String {
        if let t = fileType, !t.isEmpty { return t.lowercased() }
        if let name = originalName, let ext = name.split(separator: ".").last, name.contains(".") {
            return ext.lowercased()
        }
        return "pdf"
    }

    var isPDF: Bool { fileExtension == "pdf" }
    var remoteURL: URL? { ChannelPlusAPI.fileURL(attachmentKey) }
}

struct LanguageTags: Codable, Hashable {
    let contentLanguage: [Tag]?
    let contentLevel: [Tag]?
}

// MARK: - Programs

struct Program: Codable, Identifiable, Hashable {
    let programId: String
    let name: String
    let description: String?
    let image: ImageRef?
    let episodeCount: Int?
    let languageTags: LanguageTags?

    var id: String { programId }
    var language: String { languageTags?.contentLanguage?.first?.name ?? "其他" }
    var level: String? { languageTags?.contentLevel?.first?.name }
    var coverURL: URL? { ChannelPlusAPI.imageURL(image?.imageRef) }

    /// Description comes back as HTML; strip tags for display.
    var descriptionText: String {
        guard let description else { return "" }
        return description
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Programs grouped by language for the browse list.
struct LanguageGroup: Identifiable {
    let language: String
    let programs: [Program]
    var id: String { language }
}

// MARK: - Episodes

struct Episode: Codable, Identifiable, Hashable {
    let episodeId: String
    let title: String?
    let duration: Int?
    let episodeNumber: Int?
    let releaseDate: String?
    let voice: VoiceRef?
    let image: ImageRef?
    let attachments: [Attachment]?

    var id: String { episodeId }
    var displayTitle: String { title ?? "（無標題）" }
    var audioURL: URL? { ChannelPlusAPI.audioURL(voice?.voiceRef) }

    var releaseDateValue: Date? {
        guard let releaseDate else { return nil }
        return Episode.isoFormatter.date(from: releaseDate)
    }

    var releaseDateText: String {
        guard let d = releaseDateValue else { return "" }
        return Episode.displayFormatter.string(from: d)
    }

    var durationText: String {
        guard let duration, duration > 0 else { return "" }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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
    let playDate: String?   // raw API date string (sortable)
    let audio: String?      // remote audio URL
    let programId: String
    let programName: String
    let language: String
    let coverURL: String?
    let attachments: [Attachment]?   // optional: records saved before this field decode fine

    /// PDF attachments, the only kind we can render inline.
    var pdfAttachments: [Attachment] { (attachments ?? []).filter(\.isPDF) }

    init(episode: Episode, programId: String, programName: String,
         language: String, coverURL: String?) {
        self.id = episode.episodeId
        self.title = episode.displayTitle
        self.playDate = episode.releaseDate
        self.audio = episode.audioURL?.absoluteString
        self.programId = programId
        self.programName = programName
        self.language = language
        self.coverURL = coverURL
        self.attachments = episode.attachments
    }
}
