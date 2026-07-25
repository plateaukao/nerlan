import AppIntents
import SwiftUI
import WidgetKit

/// 最新單集 — pick a show, see (and play) its newest episodes. The counterpart to
/// Apple Podcasts' "Latest Episode": the only configurable widget in the set.
struct LatestEpisodeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.latestEpisode,
                               intent: SelectShowIntent.self,
                               provider: LatestEpisodeProvider()) { entry in
            LatestEpisodeView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("最新單集")
        .description("選一個節目，顯示並播放它最新的單集。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Configuration

/// A show the user can pick in the widget's edit sheet. Backed entirely by the
/// snapshot — the extension has no other view of the library.
struct ShowEntity: AppEntity {
    var id: String
    var name: String
    var isPodcast: Bool

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "節目" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static var defaultQuery = ShowEntityQuery()

    init(id: String, name: String, isPodcast: Bool) {
        self.id = id
        self.name = name
        self.isPodcast = isPodcast
    }

    init(_ show: WidgetShow) {
        self.init(id: show.id, name: show.name, isPodcast: show.isPodcast)
    }
}

struct ShowEntityQuery: EntityQuery {
    private var shows: [WidgetShow] { WidgetShare.loadSnapshot()?.shows ?? [] }

    func entities(for identifiers: [ShowEntity.ID]) async throws -> [ShowEntity] {
        shows.filter { identifiers.contains($0.id) }.map(ShowEntity.init)
    }

    func suggestedEntities() async throws -> [ShowEntity] {
        shows.map(ShowEntity.init)
    }
}

struct SelectShowIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "選擇節目"
    static var description = IntentDescription("選一個收藏的節目或訂閱的 Podcast。")

    @Parameter(title: "節目")
    var show: ShowEntity?

    init() {}
}

// MARK: - Timeline

struct ShowEntry: TimelineEntry {
    let date: Date
    let show: WidgetShow?
    let snapshot: WidgetSnapshot
}

struct LatestEpisodeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShowEntry {
        ShowEntry(date: Date(), show: WidgetSnapshot.preview.shows.first, snapshot: .preview)
    }

    func snapshot(for configuration: SelectShowIntent, in context: Context) async -> ShowEntry {
        entry(for: configuration, preview: context.isPreview)
    }

    func timeline(for configuration: SelectShowIntent, in context: Context) async -> Timeline<ShowEntry> {
        let entry = entry(for: configuration, preview: false)
        // Nothing here animates, and the app reloads on every library change —
        // an hourly backstop is enough to pick up a newly published episode.
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(3600)))
    }

    /// Resolve the configured show against the current snapshot. Falls back to the
    /// first show so a freshly-added widget shows something before it's edited.
    private func entry(for configuration: SelectShowIntent, preview: Bool) -> ShowEntry {
        let snapshot = preview ? .preview : (WidgetShare.loadSnapshot() ?? .empty)
        let show = configuration.show.flatMap { selected in
            snapshot.shows.first { $0.id == selected.id }
        } ?? snapshot.shows.first
        return ShowEntry(date: Date(), show: show, snapshot: snapshot)
    }
}

// MARK: - View

struct LatestEpisodeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShowEntry

    private var show: WidgetShow? { entry.show }
    private var episodes: [WidgetEpisode] { show?.latest ?? [] }

    /// Whether the player is currently playing this particular episode.
    private func isPlaying(_ episode: WidgetEpisode) -> Bool {
        entry.snapshot.isPlaying && entry.snapshot.nowPlaying?.id == episode.id
    }

    var body: some View {
        if let show {
            switch family {
            case .systemLarge: large(show)
            case .systemMedium: medium(show)
            default: small(show)
            }
        } else {
            WidgetEmptyState(systemImage: "square.grid.2x2",
                             message: "先收藏一個節目\n再選它顯示最新單集",
                             compact: family == .systemSmall)
                .widgetURL(WidgetLink.tab("programs"))
        }
    }

    private func small(_ show: WidgetShow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CoverArt(key: show.coverKey, size: 46)
                Spacer(minLength: 0)
                if let episode = episodes.first {
                    PlayPauseButton(isPlaying: isPlaying(episode), episodeId: episode.id, size: 32)
                }
            }
            Spacer(minLength: 6)
            Text(show.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(episodes.first?.title ?? "尚未取得最新單集")
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
        }
        .widgetURL(WidgetLink.show(id: show.id, isPodcast: show.isPodcast))
    }

    private func medium(_ show: WidgetShow) -> some View {
        HStack(spacing: 14) {
            CoverArt(key: show.coverKey, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(show.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(episodes.first?.title ?? "尚未取得最新單集")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let length = WidgetFormat.length(episodes.first?.duration) {
                    Text(length)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let episode = episodes.first {
                    PlayPauseButton(isPlaying: isPlaying(episode), episodeId: episode.id, size: 34)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(WidgetLink.show(id: show.id, isPodcast: show.isPodcast))
    }

    private func large(_ show: WidgetShow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: WidgetLink.show(id: show.id, isPodcast: show.isPodcast)) {
                HStack(spacing: 12) {
                    CoverArt(key: show.coverKey, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Text(show.isPodcast ? "Podcast" : show.language)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            Divider()
            if episodes.isEmpty {
                WidgetEmptyState(systemImage: "clock", message: "尚未取得最新單集")
            } else {
                VStack(spacing: 10) {
                    ForEach(episodes) { episode in
                        HStack(spacing: 10) {
                            Link(destination: WidgetLink.play(episodeId: episode.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(episode.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                    if let length = WidgetFormat.length(episode.duration) {
                                        Text(length)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            PlayPauseButton(isPlaying: isPlaying(episode), episodeId: episode.id, size: 28)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
