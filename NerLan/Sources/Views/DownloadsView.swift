import SwiftUI

/// How the Downloads / AI lists group their records.
enum RecordGrouping: String, CaseIterable, Identifiable {
    case program = "節目"
    case language = "語言"
    var id: String { rawValue }
    /// Display text. The raw values double as the persisted `@AppStorage`
    /// representation, so they stay Chinese; this is what the UI draws, and as a
    /// `LocalizedStringKey` it goes through the String Catalog.
    var label: LocalizedStringKey { LocalizedStringKey(rawValue) }
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
                    Text(group.label)
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
/// older systems. Shared with the Mac sidebar's tab bar (ContentView).
struct CapsuleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.thinMaterial, in: Capsule())
        }
    }
}

/// Groups records by the chosen key, "其他" for blanks, episodes in course order.
func groupRecords(_ records: [EpisodeRecord], by grouping: RecordGrouping)
    -> [(key: String, records: [EpisodeRecord])] {
    Dictionary(grouping: records) { grouping.key(for: $0) }
        .map { (key: $0.key.isEmpty ? String(localized: "其他") : $0.key,
                records: $0.value.sorted(by: episodeOrder)) }
        .sorted { $0.key < $1.key }
}

/// Course order: episode number first (bulk-published courses share a release
/// date, so date order degenerates to download/generation order), falling back
/// to release date — right for podcasts and records saved before `episodeNo`
/// existed — then title so equal keys stay deterministic.
private func episodeOrder(_ a: EpisodeRecord, _ b: EpisodeRecord) -> Bool {
    if let x = a.episodeNo, let y = b.episodeNo, x != y { return x < y }
    if a.playDate != b.playDate { return (a.playDate ?? "") < (b.playDate ?? "") }
    return a.title < b.title
}

/// Which offline copies the Downloads list shows: explicit downloads, streamed-
/// cache captures, or both (the default).
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case downloaded = "已下載"
    case cached = "快取"
    var id: String { rawValue }
    /// See `RecordGrouping.label` — raw values stay Chinese for persistence.
    var label: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

/// Compact filter menu beside the grouping toggle (and in the Mac sidebar
/// header). The icon fills in when a filter narrows the list.
struct DownloadFilterMenu: View {
    @Binding var selection: DownloadFilter

    var body: some View {
        Menu {
            Picker("顯示", selection: $selection) {
                ForEach(DownloadFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
        } label: {
            Image(systemName: selection == .all
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .font(.title3)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .modifier(CapsuleGlass())
    }
}

/// Offline episodes — explicit downloads plus streamed-cache captures (shown
/// with a dimmed check) — groupable by program or by language and filterable
/// by kind.
struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var player: PlayerManager
    /// AppStorage (not @State) so the Mac sidebar header's controls — which own
    /// these controls' spot up there — drive the same values.
    @AppStorage("downloadsGrouping") private var grouping: RecordGrouping = .program
    @AppStorage("downloadsFilter") private var filter: DownloadFilter = .all

    /// Ids that are cache captures rather than explicit downloads.
    private var cachedIds: Set<String> {
        Set(downloads.cachedRecords.map(\.id)).subtracting(downloads.downloadedIds)
    }

    private var visibleRecords: [EpisodeRecord] {
        switch filter {
        case .all:
            // cachedRecords excludes downloaded ids by construction; the filter
            // is a belt-and-braces guard against a double row.
            return downloads.records
                + downloads.cachedRecords.filter { !downloads.downloadedIds.contains($0.id) }
        case .downloaded: return downloads.records
        case .cached: return downloads.cachedRecords
        }
    }

    private var hasAnyRecords: Bool {
        !downloads.records.isEmpty || !downloads.cachedRecords.isEmpty
    }

    private var grouped: [(key: String, records: [EpisodeRecord])] {
        groupRecords(visibleRecords, by: grouping)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAnyRecords {
                    VStack(spacing: 0) {
                        // On Mac the sidebar's segmented header replaces the title.
                        #if !targetEnvironment(macCatalyst)
                        TopTitle(text: "下載")
                        #endif
                        ContentUnavailableView("沒有下載的單集",
                                               systemImage: "arrow.down.circle",
                                               description: Text("在節目頁面點選下載按鈕，即可離線收聽。"))
                            .frame(maxHeight: .infinity)
                    }
                } else if visibleRecords.isEmpty {
                    // Everything is hidden by the current filter; keep the
                    // title (and the pinned controls) so it can be switched back.
                    VStack(spacing: 0) {
                        #if !targetEnvironment(macCatalyst)
                        TopTitle(text: "下載")
                        #endif
                        ContentUnavailableView(
                            filter == .cached ? "沒有快取的單集" : "沒有下載的單集",
                            systemImage: filter == .cached ? "arrow.down.circle.dotted" : "arrow.down.circle",
                            description: Text(filter == .cached
                                ? "開啟串流快取後，播放過的單集會保留在這裡。"
                                : "在節目頁面點選下載按鈕，即可離線收聽。"))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    let cached = cachedIds
                    List {
                        #if !targetEnvironment(macCatalyst)
                        ScrollAwayTitle(text: "下載")
                        #endif
                        ForEach(grouped, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.records) { record in
                                    RecordRow(record: record, queue: group.records,
                                              downloadBadge: cached.contains(record.id) ? .cached : .downloaded)
                                }
                                .onDelete { offsets in
                                    for i in offsets {
                                        downloads.delete(episodeId: group.records[i].id)
                                    }
                                }
                            }
                        }
                    }
                    .contentMargins(.top, tabListTopMargin, for: .scrollContent)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pin the filter + grouping controls in the top-trailing corner,
            // aligned with the title — only when there's something to show.
            // (On Mac they live in the sidebar header instead.)
            #if !targetEnvironment(macCatalyst)
            .overlay(alignment: .topTrailing) {
                if hasAnyRecords {
                    HStack(spacing: 8) {
                        DownloadFilterMenu(selection: $filter)
                        GroupingToggle(selection: $grouping)
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 8)
                }
            }
            #endif
        }
    }
}

/// How a Downloads-list row got its local audio, shown as a trailing badge:
/// a real (user-initiated) download, or a copy captured while streaming.
enum DownloadBadge {
    case downloaded, cached
}

/// Shared row for downloads & favorites lists.
struct RecordRow: View {
    let record: EpisodeRecord
    let queue: [EpisodeRecord]
    /// Set only in the Downloads tab: marks the row as a real download (green
    /// check) or a streamed-cache capture (dimmed check).
    var downloadBadge: DownloadBadge? = nil
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
    @EnvironmentObject var notes: EpisodeNotesStore
    @State private var showAttachment = false
    @State private var editingNote = false

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
                        if let note = notes.note(for: record.id) {
                            EpisodeNoteText(text: note)
                        }
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

            if showDownload { DownloadStateButton(record: record) }

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

            if let downloadBadge {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(downloadBadge == .downloaded
                        ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            }
        }
        // Long-press only (no swipe action) so the Downloads/Favorites
        // swipe-to-delete keeps working.
        .contextMenu {
            Button {
                editingNote = true
            } label: {
                Label(notes.note(for: record.id) == nil ? "新增註記" : "編輯註記",
                      systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $editingNote) {
            EpisodeNoteEditor(episodeId: record.id, episodeTitle: record.title)
                .appEnvironment()
        }
    }

}

/// Download affordance shared by `RecordRow` and the NER episode list
/// (`EpisodeRow`): a green check once downloaded, a spinner while in flight,
/// otherwise a download button.
struct DownloadStateButton: View {
    let record: EpisodeRecord
    /// The NER list disables the button for unplayable rows (no audio URL).
    var enabled: Bool = true

    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
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
            .disabled(!enabled)
        }
    }
}
