import SwiftUI
import WidgetKit

/// 我的節目 — the shows grid: favorited NER programs and subscribed podcasts,
/// each cover tapping straight through to that show's episode list.
struct ShowsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.shows, provider: SnapshotProvider()) { entry in
            ShowsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("我的節目")
        .description("收藏的節目與訂閱的 Podcast，一按就打開。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ShowsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    /// Small fits a 2×2 block of bare covers; medium a row of four with names;
    /// large two such rows.
    private var layout: (columns: Int, limit: Int, showsNames: Bool, cover: CGFloat) {
        switch family {
        case .systemSmall: return (2, 4, false, 62)
        case .systemLarge: return (4, 8, true, 62)
        default: return (4, 4, true, 62)
        }
    }

    private var shows: [WidgetShow] { Array(entry.snapshot.shows.prefix(layout.limit)) }

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
