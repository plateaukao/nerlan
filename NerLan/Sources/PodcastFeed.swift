import Foundation

/// A subscribed podcast show plus the episodes parsed from its RSS feed. Unlike
/// the NER `Program`/`Episode` types (whose cover/audio URLs are built from
/// Channel+ keys), a podcast carries plain absolute URLs, so it stores them
/// directly. Episodes are pre-converted to `EpisodeRecord`s — the same
/// self-contained snapshot favorites/downloads/the player already hold — so
/// playback, download, favoriting, and AI all work with no podcast-specific
/// plumbing downstream.
struct PodcastFeed: Codable, Identifiable, Hashable {
    /// The RSS feed URL, used as the stable identity (and as `programId` on each
    /// episode record, so favorites/downloads group under the show).
    let id: String
    let title: String
    let author: String?
    let description: String?
    let coverURL: String?
    let language: String
    var episodes: [EpisodeRecord]

    var feedURL: String { id }

    /// Description often arrives as HTML; strip tags for display (mirrors
    /// `Program.descriptionText`).
    var descriptionText: String { description?.strippedHTML ?? "" }
}
