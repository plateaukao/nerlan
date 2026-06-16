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

/// One display sentence of a transcript plus the audio time (in seconds) at which
/// it begins, derived from the ASR segment timestamps. Persisted as a sidecar
/// (`Documents/ai/cues/{id}.json`) so the transcript screen can highlight the
/// sentence currently being spoken. Transcripts produced before this existed —
/// or with a model that returns no timestamps — simply have no cues and render
/// without highlighting.
struct TranscriptCue: Codable, Equatable {
    let start: Double
    let text: String
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
    let playDate: String?   // ISO-8601 date string (sortable)
    let audio: String?      // remote audio URL
    let programId: String
    let programName: String
    let language: String
    let coverURL: String?
    let attachments: [Attachment]?   // optional: records saved before this field decode fine
    // The following two are optional so records persisted before they existed
    // (NER `favorites.json` / `downloads.json`) still decode without migration.
    let durationSeconds: Int?        // episode length, when known
    let audioExt: String?            // audio file extension ("mp3"/"m4a"); nil ⇒ "mp3"
    // Language of the audio for monolingual sources (podcasts), so transcription
    // can force it: an ISO-639-1 code ("ko"), or "" when monolingual but the locale
    // is unknown. nil for NER programs, which are bilingual (Mandarin host + foreign
    // examples) and must not be forced. Presence (non-nil) marks a podcast.
    let audioLocale: String?

    /// PDF attachments, the only kind we can render inline.
    var pdfAttachments: [Attachment] { (attachments ?? []).filter(\.isPDF) }

    /// File extension to store the downloaded audio with (NER serves mp3).
    var audioFileExtension: String { audioExt ?? "mp3" }

    /// "H:MM:SS" for hour-plus episodes (common for podcasts), else "M:SS".
    var durationText: String {
        guard let durationSeconds, durationSeconds > 0 else { return "" }
        let h = durationSeconds / 3600, m = (durationSeconds % 3600) / 60, s = durationSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// "yyyy/MM/dd" from the ISO-8601 `playDate`, when parseable.
    var releaseDateText: String {
        guard let playDate, let d = EpisodeRecord.parseISODate(playDate) else { return "" }
        return EpisodeRecord.displayFormatter.string(from: d)
    }

    /// Tolerant ISO-8601 parse: NER dates carry fractional seconds, normalized
    /// podcast dates don't.
    static func parseISODate(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

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
        self.durationSeconds = episode.duration
        self.audioExt = nil   // NER audio is mp3
        self.audioLocale = nil   // NER programs are bilingual; never force a language
    }

    /// Raw initializer for records built outside the NER API (e.g. podcast feeds).
    init(id: String, title: String, playDate: String?, audio: String?,
         programId: String, programName: String, language: String,
         coverURL: String?, durationSeconds: Int? = nil, audioExt: String? = nil,
         audioLocale: String? = nil, attachments: [Attachment]? = nil) {
        self.id = id
        self.title = title
        self.playDate = playDate
        self.audio = audio
        self.programId = programId
        self.programName = programName
        self.language = language
        self.coverURL = coverURL
        self.durationSeconds = durationSeconds
        self.audioExt = audioExt
        self.audioLocale = audioLocale
        self.attachments = attachments
    }
}
