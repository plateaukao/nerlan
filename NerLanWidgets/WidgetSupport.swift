import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Timeline

/// One rendering of the published snapshot. The same snapshot is emitted at
/// several future dates so the progress bar advances without the app having to
/// spend a reload per minute — see `SnapshotProvider.getTimeline`.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? .preview : (WidgetShare.loadSnapshot() ?? .empty)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        completion(Timeline.snapshotTimeline(WidgetShare.loadSnapshot() ?? .empty))
    }
}

extension Timeline where EntryType == SnapshotEntry {
    /// While audio plays, hand WidgetKit half an hour of minute-by-minute entries
    /// so the progress bar and remaining time keep moving locally. Paused, one
    /// entry is enough — the app writes a fresh snapshot the moment anything
    /// actually changes.
    static func snapshotTimeline(_ snapshot: WidgetSnapshot) -> Timeline<SnapshotEntry> {
        let now = Date()
        // A snapshot that still claims to be playing hours later means the app
        // was force-quit mid-episode and never got to write the pause. Treat it
        // as stopped rather than re-arming a minute-by-minute timeline forever.
        let stale = now.timeIntervalSince(snapshot.positionAt) > 2 * 3600
        guard snapshot.isPlaying, !stale else {
            return Timeline(entries: [SnapshotEntry(date: now, snapshot: snapshot)],
                            policy: .after(now.addingTimeInterval(3600)))
        }
        let entries = (0..<30).map {
            SnapshotEntry(date: now.addingTimeInterval(Double($0) * 60), snapshot: snapshot)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }
}

// MARK: - Artwork

/// Cover art from the shared container, with the app's music-note placeholder.
/// Reads a pre-scaled JPEG the app exported — a widget process can't reach the
/// app's own cache, and must never hit the network.
struct CoverArt: View {
    let key: String?
    var size: CGFloat
    var corner: CGFloat?

    private var image: UIImage? {
        guard let url = WidgetShare.coverFileURL(key) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner ?? size / 8, style: .continuous))
    }
}

// MARK: - Controls

/// Play/pause. Backed by an `AudioPlaybackIntent`, so the system runs it in the
/// app's process (launching it in the background if need be) and audio starts
/// without the widget ever opening the app.
struct PlayPauseButton: View {
    let isPlaying: Bool
    /// Set when the widget is offering something the player hasn't loaded, so the
    /// button starts *that* episode rather than toggling whatever is loaded.
    /// `Button(intent:)` takes a concrete type, hence the branch rather than an
    /// existential.
    var episodeId: String?
    var size: CGFloat = 34

    @ViewBuilder
    var body: some View {
        if let episodeId {
            Button(intent: PlayEpisodeIntent(episodeId: episodeId)) { label }
                .buttonStyle(.plain)
        } else {
            Button(intent: TogglePlaybackIntent()) { label }
                .buttonStyle(.plain)
        }
    }

    private var label: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(.quaternary, in: Circle())
            .contentShape(Circle())
    }
}

/// Small circular glyph button (skip / next), matching PlayPauseButton's weight.
struct GlyphButton<I: AudioPlaybackIntent>: View {
    let systemName: String
    let intent: I
    var size: CGFloat = 26

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Thin capsule progress bar. Nil progress (unknown episode length) renders the
/// empty track, which reads as "not started" rather than as a broken bar.
struct ProgressBar: View {
    let progress: Double?
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: geo.size.width * (progress ?? 0))
            }
        }
        .frame(height: height)
    }
}

// MARK: - Formatting

enum WidgetFormat {
    /// "剩 12 分鐘" / "剩 45 秒", or the total length before playback starts.
    static func remaining(_ snapshot: WidgetSnapshot, at date: Date) -> String? {
        guard let duration = snapshot.nowPlaying?.duration, duration > 0 else { return nil }
        let left = max(0, duration - snapshot.position(at: date))
        if left < 60 { return "剩 \(Int(left)) 秒" }
        return "剩 \(Int(left / 60)) 分鐘"
    }

    /// "38 分鐘" — an episode's total length, for rows that aren't playing.
    static func length(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        return "\(Int(seconds / 60)) 分鐘"
    }

    /// "1 小時 12 分鐘" / "12 分鐘" — listening totals.
    static func duration(minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "\(h) 小時" : "\(h) 小時 \(m) 分"
        }
        return "\(minutes) 分鐘"
    }
}

// MARK: - Empty state

/// Shared "nothing to show yet" panel, so every widget fails the same way.
struct WidgetEmptyState: View {
    let systemImage: String
    let message: String
    var compact = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(compact ? .title3 : .title)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Gallery preview data

extension WidgetSnapshot {
    /// What the widget gallery shows before the app has published anything.
    static let preview: WidgetSnapshot = {
        func episode(_ id: String, _ title: String, _ program: String) -> WidgetEpisode {
            WidgetEpisode(id: id, title: title, programId: program, programName: program,
                          language: "日語", duration: 1_500, coverKey: nil,
                          isDownloaded: true, isPodcast: false)
        }
        return WidgetSnapshot(
            updatedAt: Date(),
            nowPlaying: episode("1", "第 12 課 買車票", "階梯日本語"),
            isPlaying: true,
            position: 420,
            positionAt: Date(),
            rate: 1,
            upNext: [episode("2", "第 13 課 在餐廳點菜", "階梯日本語"),
                     episode("3", "第 14 課 問路", "階梯日本語"),
                     episode("4", "Lesson 8 Small Talk", "空中英語教室")],
            shows: [
                WidgetShow(id: "a", name: "階梯日本語", language: "日語", coverKey: nil,
                           isPodcast: false, latest: [episode("2", "第 13 課 在餐廳點菜", "階梯日本語")]),
                WidgetShow(id: "b", name: "空中英語教室", language: "英語", coverKey: nil,
                           isPodcast: false, latest: [episode("4", "Lesson 8 Small Talk", "空中英語教室")]),
                WidgetShow(id: "c", name: "韓語一起學", language: "韓語", coverKey: nil,
                           isPodcast: false, latest: []),
                WidgetShow(id: "d", name: "法語入門", language: "法語", coverKey: nil,
                           isPodcast: false, latest: []),
            ],
            stats: WidgetStats(minutesToday: 24, minutesThisWeek: 143,
                               streakDays: 6, completedCount: 87))
    }()
}
