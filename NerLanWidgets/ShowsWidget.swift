import AppIntents
import SwiftUI
import WidgetKit

/// 我的節目 — the shows grid: favorited NER programs and subscribed podcasts,
/// each cover tapping straight through to that show's episode list.
///
/// More shows usually exist than fit, so there are two answers to "which ones":
/// by default the app ranks them by listening time (Apple's Top Shows
/// behaviour), and the edit sheet lets you pin an explicit set in an explicit
/// order. Placing several copies pinned to different shows works too.
struct ShowsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.shows,
                               intent: SelectShowsIntent.self,
                               provider: ShowsProvider()) { entry in
            ShowsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("我的節目")
        .description("收藏的節目與訂閱的 Podcast，一按就打開。可自選要顯示哪幾個。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct SelectShowsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "選擇節目"
    static var description = IntentDescription("挑選要顯示的節目；不選的話依收聽時間排序。")

    @Parameter(title: "節目")
    var shows: [ShowEntity]?

    init() {}
}

struct ShowsEntry: TimelineEntry {
    let date: Date
    let shows: [WidgetShow]
}

struct ShowsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ShowsEntry {
        ShowsEntry(date: Date(), shows: WidgetSnapshot.preview.shows)
    }

    func snapshot(for configuration: SelectShowsIntent, in context: Context) async -> ShowsEntry {
        entry(for: configuration, preview: context.isPreview)
    }

    func timeline(for configuration: SelectShowsIntent, in context: Context) async -> Timeline<ShowsEntry> {
        let entry = entry(for: configuration, preview: false)
        return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(3600)))
    }

    private func entry(for configuration: SelectShowsIntent, preview: Bool) -> ShowsEntry {
        let snapshot = preview ? .preview : (WidgetShare.loadSnapshot() ?? .empty)
        // Pinned shows win, in the order they were picked; anything since removed
        // from the library is dropped rather than left as a hole.
        guard let picked = configuration.shows, !picked.isEmpty else {
            return ShowsEntry(date: Date(), shows: snapshot.shows)
        }
        let byId = Dictionary(uniqueKeysWithValues:
            (snapshot.shows + snapshot.recentShows).map { ($0.id, $0) })
        return ShowsEntry(date: Date(), shows: picked.compactMap { byId[$0.id] })
    }
}

struct ShowsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ShowsEntry

    /// Small fits a 2×2 block of bare covers; medium a row of four with names;
    /// large two such rows.
    private var layout: (columns: Int, limit: Int, showsNames: Bool, cover: CGFloat) {
        switch family {
        case .systemSmall: return (2, 4, false, 62)
        case .systemLarge: return (4, 8, true, 62)
        default: return (4, 4, true, 62)
        }
    }

    private var shows: [WidgetShow] { Array(entry.shows.prefix(layout.limit)) }

    var body: some View {
        if shows.isEmpty {
            WidgetEmptyState(systemImage: "heart",
                             message: "點選節目旁的愛心\n就會出現在這裡",
                             compact: family == .systemSmall)
                .widgetURL(WidgetLink.tab("programs"))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if family != .systemSmall {
                    Text("我的節目")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: layout.columns),
                          alignment: .leading, spacing: 10) {
                    ForEach(shows) { show in
                        Link(destination: WidgetLink.show(id: show.id, isPodcast: show.isPodcast)) {
                            VStack(spacing: 4) {
                                CoverArt(key: show.coverKey, size: layout.cover, corner: 10)
                                if layout.showsNames {
                                    Text(show.name)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
