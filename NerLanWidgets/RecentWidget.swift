import SwiftUI
import WidgetKit

/// 最近播放 — the shows you've actually been listening to, each with a play
/// button that resumes the course where you left it: the remembered episode, at
/// the remembered offset, with the rest of the show queued behind it.
///
/// Distinct from 我的節目, which lists what you *bookmarked*. This lists what
/// you've been *doing* — which for a sequential language course is the thing you
/// want one tap from the Home Screen.
struct RecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.recent, provider: SnapshotProvider()) { entry in
            RecentView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("最近播放")
        .description("從上次停下的地方繼續，整個節目接著播。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var rowCount: Int {
        switch family {
        case .systemLarge: return 5
        case .systemMedium: return 2
        default: return 1
        }
    }

    private var shows: [WidgetShow] { Array(entry.snapshot.recentShows.prefix(rowCount)) }

    /// Whether the player is on this show's remembered episode right now.
    private func isPlaying(_ show: WidgetShow) -> Bool {
        entry.snapshot.isPlaying && entry.snapshot.nowPlaying?.programId == show.id
    }

    var body: some View {
        if shows.isEmpty {
            WidgetEmptyState(systemImage: "clock.arrow.circlepath",
                             message: "播放過的節目\n會出現在這裡",
                             compact: family == .systemSmall)
                .widgetURL(WidgetLink.tab("programs"))
        } else if family == .systemSmall, let show = shows.first {
            hero(show)
        } else {
            list
        }
    }

    /// Small: one show, big cover, resume button.
    private func hero(_ show: WidgetShow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CoverArt(key: show.coverKey, size: 46)
                Spacer(minLength: 0)
                PlayShowButton(show: show, isPlaying: isPlaying(show), size: 32)
            }
            Spacer(minLength: 6)
            Text(show.name)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(show.lastEpisodeTitle ?? "")
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
            if let progress = show.resumeProgress {
                ProgressBar(progress: progress)
                    .padding(.top, 7)
            }
        }
        .widgetURL(WidgetLink.show(id: show.id, isPodcast: show.isPodcast))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近播放")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                ForEach(shows) { show in
                    row(show)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ show: WidgetShow) -> some View {
        HStack(spacing: 10) {
            Link(destination: WidgetLink.show(id: show.id, isPodcast: show.isPodcast)) {
                HStack(spacing: 10) {
                    CoverArt(key: show.coverKey, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(show.lastEpisodeTitle ?? "")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if let progress = show.resumeProgress {
                            ProgressBar(progress: progress, height: 3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            PlayShowButton(show: show, isPlaying: isPlaying(show), size: 30)
        }
    }
}

/// Resume button for a whole show. `PlayShowIntent` runs in the app, where the
/// show's episode list becomes the player queue.
struct PlayShowButton: View {
    let show: WidgetShow
    let isPlaying: Bool
    var size: CGFloat = 30

    var body: some View {
        Button(intent: PlayShowIntent(showId: show.id, isPodcast: show.isPodcast)) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
