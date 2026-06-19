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

/// Compact program/language switch shown in the top-trailing corner, aligned
/// with the page title — replaces a full-width segmented picker so it doesn't
/// eat a whole row. One Liquid Glass capsule split into two equal halves, with
/// an accent indicator that slides to the selected half.
struct GroupingToggle: View {
    @Binding var selection: RecordGrouping
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RecordGrouping.allCases) { group in
                let isSelected = selection == group
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .padding(3)
                            .matchedGeometryEffect(id: "indicator", in: ns)
                    }
                    Text(group.rawValue)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { selection = group } }
            }
        }
        .frame(width: 140, height: 34)
        .modifier(CapsuleGlass())
    }
}

/// A Liquid Glass capsule background on iOS 26, falling back to a material on
/// older systems.
private struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
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
                    VStack(spacing: 0) {
                        TopTitle(text: "下載")
                        ContentUnavailableView("沒有下載的單集",
                                               systemImage: "arrow.down.circle",
                                               description: Text("在節目頁面點選下載按鈕，即可離線收聽。"))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    List {
                        ScrollAwayTitle(text: "下載")
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
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pin the grouping switch in the top-trailing corner, aligned with
            // the title — only when there's something to group.
            .overlay(alignment: .topTrailing) {
                if !downloads.records.isEmpty {
                    GroupingToggle(selection: $grouping)
                        .padding(.trailing, 12)
                        .padding(.top, 8)
                }
            }
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
    /// Podcast detail turns these on to get inline favorite + download buttons
    /// (like the NER episode list). Off everywhere else, so the
    /// Downloads/Favorites/AI rows are unchanged.
    var showFavorite: Bool = false
    var showDownload: Bool = false
    /// Replaces the "program · language" subtitle (podcast rows show date · duration).
    var subtitleOverride: String? = nil
    /// The podcast episode list turns AI icons off, matching the NER episode list
    /// (`EpisodeRow`) — AI is still reachable from the player and the AI tab.
    var showAI: Bool = true

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var study: StudyPanel
    @EnvironmentObject var ai: AIContentStore
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var downloads: DownloadManager
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
                        Text(subtitleOverride ?? "\(record.programName) · \(record.language)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFavorite {
                Button {
                    favorites.toggle(record)
                } label: {
                    Image(systemName: favorites.isFavorite(episodeId: record.id) ? "heart.fill" : "heart")
                        .foregroundStyle(.pink)
                }
                .buttonStyle(.borderless)
            }

            if showDownload { downloadButton }

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
                        .appEnvironment()
                }
            }

            if showAI {
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

    /// Mirrors `EpisodeRow`'s download affordance: checkmark when downloaded,
    /// spinner while in flight, otherwise a download button.
    @ViewBuilder
    private var downloadButton: some View {
        if downloads.isDownloaded(episodeId: record.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if downloads.isDownloading(episodeId: record.id) {
            ProgressView()
                .progressViewStyle(.circular)
        } else {
            Button {
                downloads.download(record)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
        }
    }
}
