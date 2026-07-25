import SwiftUI
import WidgetKit

/// 學習紀錄 — today's listening, the current streak, and the week's total. The
/// one widget with no Apple Podcasts counterpart, but NerLan already tracks all
/// of it for the 使用統計 screen and a streak is the thing a language learner
/// most wants on the Home Screen.
struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.stats, provider: SnapshotProvider()) { entry in
            StatsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("學習紀錄")
        .description("今天聽了多久、連續學習幾天。")
        .supportedFamilies([.systemSmall, .accessoryCircular,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct StatsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    private var stats: WidgetStats { entry.snapshot.stats }
    /// Daily target the circular gauge fills against. Not user-configurable —
    /// it's a progress hint, not a promise.
    private static let dailyGoalMinutes = 30.0

    private var goalProgress: Double {
        min(1, Double(stats.minutesToday) / Self.dailyGoalMinutes)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("今日 \(WidgetFormat.duration(minutes: stats.minutesToday))")
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今日學習")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(stats.minutesToday)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            Text("分鐘")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            ProgressBar(progress: goalProgress)
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("連續 \(stats.streakDays) 天")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("本週 \(stats.minutesThisWeek)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .widgetURL(WidgetLink.tab("programs"))
    }

    private var circular: some View {
        Gauge(value: goalProgress) {
            Image(systemName: "headphones")
        } currentValueLabel: {
            Text("\(stats.minutesToday)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(WidgetLink.tab("programs"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NerLan")
                .font(.caption2)
                .widgetAccentable()
            Text("今日 \(WidgetFormat.duration(minutes: stats.minutesToday))")
                .font(.caption.weight(.semibold))
            Text("連續 \(stats.streakDays) 天 · 本週 \(WidgetFormat.duration(minutes: stats.minutesThisWeek))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(WidgetLink.tab("programs"))
    }
}
