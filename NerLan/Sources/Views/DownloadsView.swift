import SwiftUI

/// Offline episodes, groupable by program or by language.
struct DownloadsView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case program = "節目"
        case language = "語言"
        var id: String { rawValue }
    }

    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: PlayerManager
    @State private var grouping: Grouping = .program

    private var grouped: [(key: String, records: [EpisodeRecord])] {
        let dict = Dictionary(grouping: downloads.records) {
            grouping == .program ? $0.programName : $0.language
        }
        return dict
            .map { (key: $0.key.isEmpty ? "其他" : $0.key, records: $0.value.sorted { ($0.playDate ?? "") < ($1.playDate ?? "") }) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty {
                    ContentUnavailableView("沒有下載的單集",
                                           systemImage: "arrow.down.circle",
                                           description: Text("在節目頁面點選下載按鈕，即可離線收聽。"))
                } else {
                    List {
                        ForEach(grouped, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.records) { record in
                                    RecordRow(record: record, queue: group.records)
                                }
                                .onDelete { offsets in
                                    for i in offsets {
                                        downloads.delete(episodeId: group.records[i].id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("下載")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("分組", selection: $grouping) {
                        ForEach(Grouping.allCases) { g in
                            Text(g.rawValue).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }
        }
    }
}

/// Shared row for downloads & favorites lists.
struct RecordRow: View {
    let record: EpisodeRecord
    let queue: [EpisodeRecord]

    @EnvironmentObject var player: PlayerManager

    private var isCurrent: Bool { player.current?.id == record.id }

    var body: some View {
        Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                player.play(record, in: queue)
            }
        } label: {
            HStack(spacing: 12) {
                CoverImage(urlString: record.coverURL, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.subheadline)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(2)
                    Text("\(record.programName) · \(record.language)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
