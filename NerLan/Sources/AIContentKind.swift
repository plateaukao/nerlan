import Foundation

/// The four AI study artifacts and every name each is known by across the
/// storage/sync stack — the single source of truth shared by `AIContentStore`
/// (local `Documents/ai/...` files), `ICloudSync` (fixed ASCII filenames inside
/// per-episode cloud folders), and `DriveSync` (flat `<kind>-<id>.<ext>` names
/// in the appDataFolder). Adding a kind here is the whole change; the sync
/// engines iterate `allCases`.
enum AIContentKind: CaseIterable {
    case transcript, handout, cues, translation

    /// Subdirectory under `Documents/ai/` holding the local file.
    var localSub: String {
        switch self {
        case .transcript: return "transcripts"
        case .handout: return "handouts"
        case .cues: return "cues"
        case .translation: return "translations"
        }
    }

    /// File extension, shared by the local file and both mirrors.
    var localExt: String {
        switch self {
        case .transcript: return "txt"
        case .handout: return "html"
        case .cues, .translation: return "json"
        }
    }

    /// The kind's bare name — the iCloud filename stem and the Drive prefix.
    private var stem: String {
        switch self {
        case .transcript: return "transcript"
        case .handout: return "handout"
        case .cues: return "cues"
        case .translation: return "translation"
        }
    }

    /// Fixed ASCII filename inside an episode's iCloud folder.
    var cloudFile: String { "\(stem).\(localExt)" }

    var mime: String {
        switch self {
        case .transcript: return "text/plain"
        case .handout: return "text/html"
        case .cues, .translation: return "application/json"
        }
    }

    /// Drive's flat per-artifact name, e.g. "transcript-<id>.txt".
    func driveName(id: String) -> String { "\(stem)-\(id).\(localExt)" }

    /// The (kind, id) a Drive file name maps to — nil when the name isn't an
    /// AI content file, or carries a junk id that must not be synced.
    static func parseDriveName(_ name: String) -> (kind: AIContentKind, id: String)? {
        for kind in allCases {
            let prefix = kind.stem + "-", suffix = "." + kind.localExt
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard isValidEpisodeId(id) else { return nil }
            return (kind, id)
        }
        return nil
    }

    /// A real episode id is a UUID or "pod-<hex>": ASCII letters, digits and
    /// hyphens only. Anything else is junk left by an earlier bug (truncated
    /// iCloud folder names pulled as ids) and must not be stored or synced.
    static func isValidEpisodeId(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
