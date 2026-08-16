import AppIntents
import Combine
import Foundation

// Siri transcribes speech in *its own* language, not the show's. With Siri set to
// English, a Korean title is never transcribed as 한국어 and a French one loses its
// accents — so matching a spoken utterance against the raw title fails for exactly
// the shows this app exists to teach.
//
// Three answers, weakest to strongest:
//
//  1. Transliteration — "français" folds to "francais", 한국어 romanizes to
//     "hangug-eo". Reliable for Latin-script languages, rough for CJK.
//  2. Language aliases — "play the Korean podcast in NerLan". No romanization
//     guesswork, and it's the phrasing a language learner reaches for anyway.
//  3. A nickname the user assigns. The guaranteed escape hatch: whatever they
//     can actually say becomes the show's handle.
//
// All three are published as `DisplayRepresentation.synonyms`, which is what Siri
// voice-matches an entity by, and all three are checked when matching free text.

/// Spoken nicknames per show, keyed by the same id everything else uses
/// (`programId`, or the feed URL for a podcast). Plain JSON in Documents, like
/// every other store here.
final class ShowNicknameStore: ObservableObject {
    static let shared = ShowNicknameStore()

    @Published private(set) var names: [String: String] = [:]

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("siri-names.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            names = saved
        }
    }

    func nickname(for showId: String) -> String? {
        names[showId]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func set(_ nickname: String?, for showId: String) {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if names[showId] == trimmed { return }
        if let trimmed {
            names[showId] = trimmed
        } else {
            names.removeValue(forKey: showId)
        }
        try? JSONEncoder().encode(names).write(to: fileURL)
        // A nickname is only useful once Siri has been told about it.
        SiriCatalog.publish()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum SiriNaming {
    /// Case-, accent- and width-insensitive, with spaces removed. Siri's
    /// transcription varies in all four.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                  locale: .current)
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Latin transliteration of a non-Latin title — Hangul, kana and Han all
    /// romanize. Nil when the title is already Latin (nothing gained).
    static func romanized(_ title: String) -> String? {
        guard let latin = title.applyingTransform(.toLatin, reverse: false) else { return nil }
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return fold(plain) == fold(title) ? nil : plain
    }

    /// English names for the app's Chinese language labels — the ones both
    /// `Program.language` and `PodcastFeedParser.mappedLanguage` produce.
    static func englishLanguages(_ label: String) -> [String] {
        switch label {
        case "英語": return ["English"]
        case "日語": return ["Japanese"]
        case "韓語": return ["Korean"]
        case "法語": return ["French"]
        case "德語": return ["German"]
        case "西語", "西班牙語": return ["Spanish"]
        case "義大利語": return ["Italian"]
        case "葡萄牙語": return ["Portuguese"]
        case "俄語": return ["Russian"]
        case "越南語": return ["Vietnamese"]
        case "印尼語": return ["Indonesian"]
        case "泰語": return ["Thai"]
        case "馬來語": return ["Malay"]
        case "緬甸語": return ["Burmese"]
        case "菲律賓語": return ["Filipino", "Tagalog"]
        case "柬埔寨語", "高棉語": return ["Khmer", "Cambodian"]
        case "阿拉伯語": return ["Arabic"]
        case "中文", "華語", "國語": return ["Chinese", "Mandarin"]
        case "台語", "閩南語": return ["Taiwanese", "Hokkien"]
        case "客語", "客家語": return ["Hakka"]
        case "原住民族語": return ["Indigenous"]
        default: return []
        }
    }

    /// Everything a spoken phrase could reasonably mean by this show. The title
    /// itself is the display name and comes first; the rest are the synonyms.
    static func aliases(title: String, language: String, isPodcast: Bool,
                        nickname: String?) -> [String] {
        var out: [String] = [title]
        if let nickname { out.append(nickname) }
        if let roman = romanized(title) { out.append(roman) }
        // The accent-stripped form matters for French/Spanish/German, where the
        // recognizer drops diacritics an English keyboard never types.
        let plain = title.applyingTransform(.stripDiacritics, reverse: false) ?? title
        if plain != title { out.append(plain) }
        // "the Korean podcast" / "my French program" — the phrasing that needs no
        // romanization at all, and the one a learner actually reaches for.
        let kind = isPodcast ? "podcast" : "program"
        for name in englishLanguages(language) {
            out.append(name)
            out.append("\(name) \(kind)")
            // A phrasing with no media noun in it. Saying "podcast" out loud is
            // what tips Siri's media classifier toward Apple Podcasts, so give
            // the user a way to name the show that avoids the word entirely.
            out.append("\(name) lesson")
        }
        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert(fold($0)).inserted }
    }

    /// Synonyms for a `DisplayRepresentation` — the aliases minus the title,
    /// which is already the display name.
    static func synonyms(title: String, language: String, isPodcast: Bool,
                         nickname: String?) -> [LocalizedStringResource] {
        aliases(title: title, language: language, isPodcast: isPodcast, nickname: nickname)
            .dropFirst()
            .map { LocalizedStringResource(stringLiteral: $0) }
    }

    /// Does a spoken utterance name this show? Substring either way (Siri adds
    /// and drops filler), else a majority of the spoken words appearing in one
    /// alias — which is how a rough romanization still lands.
    static func matches(_ spoken: String, aliases: [String]) -> Bool {
        let needle = fold(spoken)
        guard !needle.isEmpty else { return false }
        for alias in aliases {
            let hay = fold(alias)
            guard !hay.isEmpty else { continue }
            if hay.contains(needle) || needle.contains(hay) { return true }
        }
        let words = spoken.split(whereSeparator: { $0 == " " || $0.isPunctuation })
            .map { fold(String($0)) }
            .filter { $0.count > 1 }
        guard words.count > 1 else { return false }
        for alias in aliases {
            let hay = fold(alias)
            guard !hay.isEmpty else { continue }
            let hits = words.filter { hay.contains($0) }.count
            if hits * 2 > words.count { return true }
        }
        return false
    }
}
