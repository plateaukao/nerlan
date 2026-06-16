import CryptoKit
import Foundation

/// Parses a podcast RSS feed into a `PodcastFeed` (+ its episodes as
/// `EpisodeRecord`s). Uses Foundation's SAX `XMLParser` — no third-party
/// dependency, matching the rest of the app. Namespace processing is left off so
/// qualified element names (`itunes:image`, `itunes:duration`) arrive verbatim.
enum PodcastFeedParser {
    enum ParseError: LocalizedError {
        case malformed
        case noEpisodes
        var errorDescription: String? {
            switch self {
            case .malformed: return "無法解析這個 RSS"
            case .noEpisodes: return "這個 RSS 沒有可播放的單集"
            }
        }
    }

    static func parse(_ data: Data, feedURL: URL) throws -> PodcastFeed {
        let delegate = Delegate(feedURL: feedURL.absoluteString)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ParseError.malformed }
        let feed = delegate.makeFeed()
        guard !feed.episodes.isEmpty else { throw ParseError.noEpisodes }
        return feed
    }
}

// MARK: - SAX delegate

private final class Delegate: NSObject, XMLParserDelegate {
    private let feedURL: String
    init(feedURL: String) { self.feedURL = feedURL }

    // Channel-level
    private var channelTitle = ""
    private var channelDescription = ""
    private var channelAuthor = ""
    private var channelLanguage = ""
    private var channelImage = ""

    // Parse state
    private var inItem = false
    private var inChannelImage = false   // inside the channel's <image> block
    private var text = ""

    // Accumulator for the current <item>
    private struct Item {
        var title = "", audio = "", audioType = "", guid = "", pubDate = "", duration = "", image = ""
    }
    private var item = Item()
    private var items: [Item] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        switch elementName {
        case "item":
            inItem = true
            item = Item()
        case "image":
            if !inItem { inChannelImage = true }
        case "itunes:image":
            let href = attributes["href"] ?? ""
            if inItem { item.image = href }
            else if channelImage.isEmpty { channelImage = href }
        case "enclosure":
            if inItem {
                item.audio = attributes["url"] ?? ""
                item.audioType = attributes["type"] ?? ""
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch elementName {
            case "title": if item.title.isEmpty { item.title = value }
            case "guid": if item.guid.isEmpty { item.guid = value }
            case "pubDate": item.pubDate = value
            case "itunes:duration": item.duration = value
            case "item": inItem = false; items.append(item)
            default: break
            }
        } else {
            switch elementName {
            case "title": if !inChannelImage, channelTitle.isEmpty { channelTitle = value }
            case "description", "itunes:summary":
                if channelDescription.isEmpty, !value.isEmpty { channelDescription = value }
            case "itunes:author", "author":
                if channelAuthor.isEmpty, !value.isEmpty { channelAuthor = value }
            case "language": if channelLanguage.isEmpty { channelLanguage = value }
            case "url": if inChannelImage, channelImage.isEmpty { channelImage = value }
            case "image": inChannelImage = false
            default: break
            }
        }
        text = ""
    }

    // MARK: - Build

    func makeFeed() -> PodcastFeed {
        let language = Self.mappedLanguage(channelLanguage)
        // The feed is monolingual, so keep the raw locale (e.g. "ko") to force the
        // transcription language. Use "" when the feed declares no usable code: that
        // still marks the record as a (monolingual) podcast — distinct from nil/NER —
        // so transcription skips the Chinese teaching prompt and lets whisper detect.
        let locale = Self.localeCode(channelLanguage) ?? ""
        let cover = channelImage.isEmpty ? nil : channelImage
        let records: [EpisodeRecord] = items.compactMap { acc in
            guard !acc.audio.isEmpty else { return nil }   // unplayable without audio
            let key = acc.guid.isEmpty ? acc.audio : acc.guid
            return EpisodeRecord(
                id: "pod-" + Self.sha256Hex(key),
                title: acc.title.isEmpty ? "（無標題）" : acc.title,
                playDate: Self.isoDate(from: acc.pubDate),
                audio: acc.audio,
                programId: feedURL,
                programName: channelTitle,
                language: language,
                coverURL: acc.image.isEmpty ? cover : acc.image,
                durationSeconds: Self.durationSeconds(acc.duration),
                audioExt: Self.audioExt(type: acc.audioType, url: acc.audio),
                audioLocale: locale,
                attachments: nil)
        }
        return PodcastFeed(
            id: feedURL,
            title: channelTitle,
            author: channelAuthor.isEmpty ? nil : channelAuthor,
            description: channelDescription.isEmpty ? nil : channelDescription,
            coverURL: cover,
            language: language,
            episodes: records)
    }

    // MARK: - Field helpers

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `itunes:duration` is seconds ("1234"/"1234.5") or "HH:MM:SS" / "MM:SS".
    private static func durationSeconds(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":").map { Int($0) ?? 0 }
            switch parts.count {
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: return parts[0] * 60 + parts[1]
            default: return nil
            }
        }
        if let i = Int(s) { return i }
        if let d = Double(s) { return Int(d) }
        return nil
    }

    /// Storage extension from the enclosure MIME type, else the URL's path
    /// extension, defaulting to mp3.
    private static func audioExt(type: String, url: String) -> String {
        switch type.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/aac": return "m4a"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        default: break
        }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["mp3", "m4a", "aac", "ogg", "opus", "wav", "mp4"].contains(ext) ? ext : "mp3"
    }

    /// Normalize an RFC-822 `pubDate` to an ISO-8601 string so it sorts and
    /// renders consistently with NER's `playDate` strings. Returns nil if
    /// unparseable (the row then shows no date).
    private static func isoDate(from rfc822: String) -> String? {
        guard !rfc822.isEmpty else { return nil }
        for f in rfc822Formatters {
            if let d = f.date(from: rfc822) { return isoOut.string(from: d) }
        }
        return nil
    }

    private static let rfc822Formatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z",
         "EEE, dd MMM yyyy HH:mm:ss zzz",
         "dd MMM yyyy HH:mm:ss Z",
         "EEE, dd MMM yyyy HH:mm Z"].map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()
    private static let isoOut = ISO8601DateFormatter()

    /// The feed's `<language>` reduced to an ISO-639-1 primary subtag (e.g.
    /// "ko-KR" → "ko", "en-us" → "en"), suitable for the transcription `language`
    /// parameter. nil when the feed declares no usable 2-letter code, in which case
    /// whisper auto-detects.
    private static func localeCode(_ code: String) -> String? {
        let primary = code.lowercased().split(separator: "-").first.map(String.init) ?? ""
        let isISO2 = primary.count == 2 && primary.allSatisfy { $0.isLetter && $0.isASCII }
        return isISO2 ? primary : nil
    }

    /// Map an RSS `<language>` code to the Chinese learning-language label the
    /// transcription prompt is primed for (see `OpenAIService.transcriptionPrompt`);
    /// fall back to a generic label.
    private static func mappedLanguage(_ code: String) -> String {
        let lang = code.lowercased().split(separator: "-").first.map(String.init) ?? code.lowercased()
        switch lang {
        case "en": return "英語"
        case "ja": return "日語"
        case "ko": return "韓語"
        case "fr": return "法語"
        case "de": return "德語"
        case "es": return "西語"
        case "vi": return "越南語"
        case "id": return "印尼語"
        case "th": return "泰語"
        case "zh": return "中文"
        default: return "Podcast"
        }
    }
}
