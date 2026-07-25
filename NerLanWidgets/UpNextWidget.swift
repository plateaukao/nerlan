import SwiftUI
import WidgetKit

/// 繼續收聽 — the Up Next widget: whatever is loaded in the player, plus the rest
/// of the queue. With nothing loaded it offers the most recent download or
/// favorite instead, so the widget is useful from the first launch.
struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.upNext, provider: SnapshotProvider()) { entry in
            UpNextView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("繼續收聽")
        .description("顯示正在播放的單集，並直接播放接下來的內容。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct UpNextView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    /// What the widget acts on: the loaded episode, else the top suggestion.
    private var lead: WidgetEpisode? { snapshot.leadEpisode }
    /// The player is only really "playing" the lead when it's the loaded one.
    private var isPlayingLead: Bool { snapshot.nowPlaying != nil && snapshot.isPlaying }

    var body: some View {
        switch family {
        case .accessoryInline: inlineBody
        case .accessoryCircular: circularBody
        case .accessoryRectangular: rectangularBody
        case .systemLarge: largeBody
        case .systemMedium: mediumBody
        default: smallBody
        }
    }

    // MARK: - Home Screen

    private var smallBody: some View {
        Group {
            if let lead {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        CoverArt(key: lead.coverKey, size: 46)
                        Spacer(minLength: 0)
                        PlayPauseButton(isPlaying: isPlayingLead,
                                        episodeId: snapshot.nowPlaying == nil ? lead.id : nil,
                                        size: 32)
                    }
                    Spacer(minLength: 6)
                    header(lead)
                    if snapshot.nowPlaying != nil {
                        ProgressBar(progress: snapshot.progress(at: entry.date))
                            .padding(.top, 7)
                    }
                }
            } else {
                emptyState
            }
        }
        .widgetURL(WidgetLink.player)
    }

    private var mediumBody: some View {
        Group {
            if let lead {
                HStack(spacing: 14) {
                    CoverArt(key: lead.coverKey, size: 96)
                    VStack(alignment: .leading, spacing: 5) {
                        header(lead)
                        Spacer(minLength: 2)
                        if snapshot.nowPlaying != nil {
                            ProgressBar(progress: snapshot.progress(at: entry.date))
                            if let remaining = WidgetFormat.remaining(snapshot, at: entry.date) {
                                Text(remaining)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let length = WidgetFormat.length(lead.duration) {
                            Text(length)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        transport(lead)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                emptyState
            }
        }
        .widgetURL(WidgetLink.player)
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let lead {
                Link(destination: WidgetLink.player) {
                    HStack(spacing: 12) {
                        CoverArt(key: lead.coverKey, size: 84)
                        VStack(alignment: .leading, spacing: 5) {
                            header(lead)
                            if snapshot.nowPlaying != nil {
                                ProgressBar(progress: snapshot.progress(at: entry.date))
                                if let remaining = WidgetFormat.remaining(snapshot, at: entry.date) {
                                    Text(remaining)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                transport(lead)
                    .frame(maxWidth: .infinity)
            } else {
                emptyState
            }

            // Everything after the lead episode. On the "nothing loaded" path the
            // lead itself came out of upNext, so skip it here.
            let rest = Array(snapshot.upNext.drop(while: { $0.id == lead?.id }).prefix(3))
            if !rest.isEmpty {
                Divider()
                Text("接下來")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(rest) { episode in
                        queueRow(episode)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Title block shared by every system family.
    private func header(_ episode: WidgetEpisode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.programName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(episode.title)
                .font(family == .systemSmall ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
                .lineLimit(2)
        }
    }

    private func transport(_ lead: WidgetEpisode) -> some View {
        HStack(spacing: 20) {
            GlyphButton(systemName: "gobackward.15", intent: SkipIntent(seconds: -15))
                .opacity(snapshot.nowPlaying == nil ? 0.35 : 1)
            PlayPauseButton(isPlaying: isPlayingLead,
                            episodeId: snapshot.nowPlaying == nil ? lead.id : nil,
                            size: 38)
            GlyphButton(systemName: "forward.fill", intent: NextEpisodeIntent())
                .opacity(snapshot.upNext.isEmpty ? 0.35 : 1)
        }
    }

    private func queueRow(_ episode: WidgetEpisode) -> some View {
        HStack(spacing: 10) {
            Link(destination: WidgetLink.play(episodeId: episode.id)) {
                HStack(spacing: 10) {
                    CoverArt(key: episode.coverKey, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(episode.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(episode.programName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            PlayPauseButton(isPlaying: false, episodeId: episode.id, size: 26)
        }
    }

    private var emptyState: some View {
        WidgetEmptyState(systemImage: "headphones",
                         message: "還沒有可以播放的單集\n先下載或收藏一集吧",
                         compact: family == .systemSmall)
    }

    // MARK: - Lock Screen

    @ViewBuilder
    private var inlineBody: some View {
        if let lead {
            Label(lead.title, systemImage: isPlayingLead ? "waveform" : "pause.fill")
        } else {
            Label("NerLan", systemImage: "headphones")
        }
    }

    private var circularBody: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Circle()
                    .stroke(.tertiary, lineWidth: 4)
                    .padding(3)
                Circle()
                    .trim(from: 0, to: snapshot.progress(at: entry.date) ?? 0)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(3)
                Image(systemName: isPlayingLead ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangularBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lead {
                Text(lead.programName)
                    .font(.caption2)
                    .widgetAccentable()
                    .lineLimit(1)
                Text(lead.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if snapshot.nowPlaying != nil, let progress = snapshot.progress(at: entry.date) {
                    ProgressBar(progress: progress, height: 3)
                        .padding(.top, 1)
                }
            } else {
                Text("NerLan").font(.caption2).widgetAccentable()
                Text("還沒有可以播放的單集").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetLink.player)
    }
}
