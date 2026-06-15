import Charts
import SwiftUI

/// 使用統計 — listening behavior over time: accumulated time, completed episodes,
/// streak, period subtotals, a day/week/month bar chart, and the most-listened
/// programs. All numbers come from `ListeningStatsStore` (merged across devices).
struct UsageStatsView: View {
    @EnvironmentObject var stats: ListeningStatsStore
    @State private var range: ChartRange = .day

    enum ChartRange: String, CaseIterable, Identifiable {
        case day = "日", week = "週", month = "月"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            if stats.hasData {
                summarySection
                chartSection
                programSection
            } else {
                Section {
                    Text("開始聆聽後，這裡會顯示你的使用統計。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("使用統計")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        Section {
            LabeledContent("總聆聽時間", value: Self.durationText(stats.totalSeconds))
            LabeledContent("完成單集", value: "\(stats.completedCount)")
            LabeledContent("連續聆聽天數",
                           value: stats.currentStreak > 0 ? "🔥 \(stats.currentStreak) 天" : "—")
            LabeledContent("今日", value: Self.durationText(stats.secondsToday))
            LabeledContent("本週", value: Self.durationText(stats.secondsThisWeek))
            LabeledContent("本月", value: Self.durationText(stats.secondsThisMonth))
        }
    }

    private var chartSection: some View {
        Section {
            Picker("範圍", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            chart
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch range {
        case .day:
            Chart(stats.hourlyTodayStats()) { stat in
                BarMark(x: .value("時", stat.hour), y: .value("分鐘", stat.seconds / 60))
                    .foregroundStyle(.tint)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) { Text("\(h)時") }
                    }
                }
            }
        case .week, .month:
            Chart(stats.dailySeries(lastDays: range == .week ? 7 : 30)) { stat in
                BarMark(x: .value("日期", stat.date, unit: .day), y: .value("分鐘", stat.seconds / 60))
                    .foregroundStyle(.tint)
            }
            .chartXAxis {
                if range == .week {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisTick()
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                } else {
                    AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var programSection: some View {
        let top = stats.topPrograms(3)
        if !top.isEmpty {
            Section("最常聽節目") {
                ForEach(top) { program in
                    LabeledContent(program.name, value: Self.durationText(program.seconds))
                }
            }
        }
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h) 小時 \(m) 分" }
        if m > 0 { return "\(m) 分" }
        return total > 0 ? "\(total) 秒" : "0 分"
    }
}
