import SwiftUI

/// How the Downloads / AI lists group their records.
enum RecordGrouping: String, CaseIterable, Identifiable {
    case program = "節目"
    case language = "語言"
    var id: String { rawValue }
    func key(for record: EpisodeRecord) -> String {
        self == .program ? record.programName : record.language
    }
}

/// Segmented program/language switcher placed at the top of the content (not in
/// the nav bar, where it crowds the tab/nav chrome in the narrow iPad column).
struct GroupingPicker: View {
    @Binding var selection: RecordGrouping
    var body: some View {
        Picker("分組", selection: $selection) {
            ForEach(RecordGrouping.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Groups records by the chosen key, "其他" for blanks, episodes oldest-first.
func groupRecords(_ records: [EpisodeRecord], by grouping: RecordGrouping)
    -> [(key: String, records: [EpisodeRecord])] {
    Dictionary(grouping: records) { grouping.key(for: $0) }
        .map { (key: $0.key.isEmpty ? "其他" : $0.key,
                records: $0.value.sorted { ($0.playDate ?? "") < ($1.playDate ?? "") }) }
        .sorted { $0.key < $1.key }
}

/// Offline episodes, groupable by program or by language.
struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: PlayerManager
    @State private var grouping: RecordGrouping = .program

    private var grouped: [(key: String, records: [EpisodeRecord])] {
        groupRecords(downloads.records, by: grouping)
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty {
                    ContentUnavailableView("沒有下載的單集",
                                           systemImage: "arrow.down.circle",
                                           description: Text("在節目頁面點選下載按鈕，即可離線收聽。"))
                } else {
                    VStack(spacing: 0) {
                        GroupingPicker(selection: $grouping)
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
            }
            .navigationTitle("下載")
        }
    }
}

/// Shared row for downloads & favorites lists.
struct RecordRow: View {
    let record: EpisodeRecord
    let queue: [EpisodeRecord]
    /// In the AI tab: show transcript/handout buttons only for content that
    /// already exists (regardless of whether an API key is set), so the user can
    /// open it without seeing idle "generate" buttons.
    var aiReadyOnly: Bool = false

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var study: StudyPanel
    @EnvironmentObject var ai: AIContentStore
    @State private var showAttachment = false

    private var isCurrent: Bool { player.current?.id == record.id }

    var body: some View {
        HStack(spacing: 12) {
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

            if !record.pdfAttachments.isEmpty {
                Button {
                    if StudyPanel.usesSidePanel {
                        study.item = .attachment(record)
                    } else {
                        showAttachment = true
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .sheet(isPresented: $showAttachment) {
                    AttachmentView(title: record.title, attachments: record.pdfAttachments,
                                   onClose: { showAttachment = false })
                }
            }

            if aiReadyOnly {
                if ai.hasTranscript(record.id) {
                    AIActionButton(kind: .transcript, record: record, compact: true)
                }
                if ai.hasHandout(record.id) {
                    AIActionButton(kind: .handout, record: record, compact: true)
                }
            } else if settings.hasAPIKey {
                AIActionButton(kind: .transcript, record: record, compact: true)
                AIActionButton(kind: .handout, record: record, compact: true)
            }
        }
    }
}
