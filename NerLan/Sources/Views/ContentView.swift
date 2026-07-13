import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var ai: AIContentStore
    @EnvironmentObject var study: StudyPanel
    @EnvironmentObject var downloads: DownloadManager
    @State private var showPlayer = false
    /// iPhone-only: a transcript the store asked to auto-open once its first chunk
    /// landed (see `AIContentStore.presentTranscript`). Presented from here — the
    /// stable root — so it shows even after the player sheet that started it is
    /// gone. iPad routes through the always-visible side panel instead.
    @State private var autoTranscript: EpisodeRecord?
    /// Mac only: collapses the left (browser) column of the split layout so the
    /// study panel gets the whole window. Persisted like a real sidebar state.
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    #if targetEnvironment(macCatalyst)
    /// Mac left column: which section the segmented header shows.
    @AppStorage("macSidebarTab") private var macSidebarTab = 0
    // Shared with DownloadsView / AITabView, whose grouping toggles move up
    // into the header on Mac.
    @AppStorage("downloadsGrouping") private var downloadsGrouping: RecordGrouping = .program
    @AppStorage("aiGrouping") private var aiGrouping: RecordGrouping = .program
    #endif

    var body: some View {
        Group {
            if StudyPanel.usesSidePanel {
                splitLayout
            } else {
                tabs
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .appEnvironment()
        }
        .sheet(item: $autoTranscript) { record in
            TranscriptView(record: record,
                           text: ai.transcriptText(record.id) ?? "",
                           cues: ai.transcriptCues(record.id),
                           onClose: { autoTranscript = nil })
                .appEnvironment()
        }
        .onChange(of: ai.presentTranscript) { _, record in
            guard let record else { return }
            ai.presentTranscript = nil
            presentTranscriptView(record)
        }
        // Pull anything new from Google Drive on launch (no-op unless Drive sync is
        // on and signed in). iCloud sync starts itself from the store inits.
        .task { DriveSync.shared.syncNow() }
        .onAppear { attachMacToolbar() }
    }

    /// Mac only: hang the sidebar-toggle toolbar off the window titlebar.
    private func attachMacToolbar() {
        #if targetEnvironment(macCatalyst)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            // Not connected yet on the very first appear — retry next runloop.
            DispatchQueue.main.async { attachMacToolbar() }
            return
        }
        MacToolbar.shared.attach(to: scene)
        #endif
    }

    /// Open a freshly-ready transcript from the stable root: the side panel on
    /// iPad, a root sheet on iPhone. If the player sheet is up it's dismissed first
    /// (you can't stack two root sheets), then the transcript presents once that
    /// dismissal animation finishes — audio keeps playing via the mini player.
    private func presentTranscriptView(_ record: EpisodeRecord) {
        if StudyPanel.usesSidePanel {
            showPlayer = false
            study.item = .transcript(record)
        } else if showPlayer {
            showPlayer = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { autoTranscript = record }
        } else {
            autoTranscript = record
        }
    }

    /// iPad: the browser on the left, the transcript / handout / 講義 panel on
    /// the right. (iPhone stays portrait-locked → the plain tabs.)
    ///
    /// Uses `legacyTabs` (the explicit MiniPlayerBar overlay) rather than the
    /// iOS 26 `tabViewBottomAccessory`: the system accessory re-lays-out on every
    /// 0.5s playback tick inside this narrowed column, which makes its cover
    /// thumbnail flicker. The plain overlay bar is stable.
    private var splitLayout: some View {
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebarColumn
                    .frame(width: 390)
                Divider()
            }
            studyPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The toggle writes UserDefaults from AppKit (titlebar) or the menu
        // command, so animate on the value change rather than withAnimation.
        .animation(.easeInOut(duration: 0.2), value: sidebarHidden)
        // When a new episode starts, default the panel to its study content,
        // preferring a PDF handout, then the AI handout, then the transcript.
        .onChange(of: player.current) { _, record in
            showDefaultStudy(for: record)
        }
    }

    /// The split layout's left column. On Mac the bottom tab bar is replaced by
    /// a segmented header (Catalyst moves a root tab bar into the titlebar on
    /// macOS 15, where it collides with the NSToolbar); iPad keeps the TabView.
    @ViewBuilder
    private var sidebarColumn: some View {
        #if targetEnvironment(macCatalyst)
        macSidebar
        #else
        legacyTabs
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private var macSidebar: some View {
        VStack(spacing: 0) {
            macSidebarHeader
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Group {
                switch macSidebarTab {
                case 1: FavoritesView()
                case 2: DownloadsView()
                case 3: AITabView()
                default: ProgramListView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keep list content clear of the floating mini player, same
            // reserve as the study panel's.
            .padding(.bottom, player.current != nil ? 72 : 0)
        }
        .overlay(alignment: .bottom) {
            if player.current != nil {
                MiniPlayerBar { showPlayer = true }
                    .padding(.bottom, 8)
            }
        }
    }

    /// The 節目/收藏/下載/AI switch sitting where the page titles live on iOS,
    /// with the selected section's title-row accessory beside it.
    private var macSidebarHeader: some View {
        HStack(spacing: 8) {
            MacTabBar(selection: $macSidebarTab)
            switch macSidebarTab {
            case 0:
                Button {
                    NotificationCenter.default.post(name: .addPodcast, object: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .contentShape(Rectangle())
                }
                .help("加入 Podcast")
            case 2 where !downloads.records.isEmpty:
                GroupingToggle(selection: $downloadsGrouping)
            case 3 where !ai.aiRecords.isEmpty:
                GroupingToggle(selection: $aiGrouping)
            default:
                EmptyView()
            }
        }
        .frame(height: 34)
    }
    #endif

    /// The right-hand study panel. On Mac, while the sidebar is hidden the mini
    /// player moves here so playback stays reachable; the sidebar toggle lives
    /// in the window titlebar (see `MacToolbar`).
    /// Whether the mini player is riding on the study panel right now.
    private var showsPanelMiniPlayer: Bool {
        sidebarHidden && player.current != nil
    }

    @ViewBuilder
    private var studyPanel: some View {
        #if targetEnvironment(macCatalyst)
        StudyDetailView()
            // Hard padding, not a safe-area inset: the handout webview ignores
            // the bottom safe area, so an inset would still let it run under
            // the bar. 72 = bar (56) + its bottom padding (8) + a gap (8).
            .padding(.bottom, showsPanelMiniPlayer ? 72 : 0)
            .overlay(alignment: .bottom) {
                if showsPanelMiniPlayer {
                    MiniPlayerBar { showPlayer = true }
                        .padding(.bottom, 8)
                }
            }
        #else
        StudyDetailView()
        #endif
    }

    private func showDefaultStudy(for record: EpisodeRecord?) {
        guard let record else { study.item = nil; return }
        if !record.pdfAttachments.isEmpty {
            study.item = .attachment(record)
        } else if ai.hasHandout(record.id) {
            study.item = .handout(record)
        } else if ai.hasTranscript(record.id) {
            study.item = .transcript(record)
        } else {
            study.item = nil
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.1, *) {
            modernTabs
        } else {
            legacyTabs
        }
    }

    /// iOS 26.1+: native Liquid Glass mini player capsule (Apple Music style).
    /// The system floats it above the tab bar, and tabBarMinimizeBehavior
    /// collapses the tab bar on scroll with the accessory sliding inline.
    /// isEnabled (26.1+) hides the capsule when nothing is playing — a
    /// conditional inside the content closure would leave an empty capsule.
    @available(iOS 26.1, *)
    private var modernTabs: some View {
        TabView {
            Tab("節目", systemImage: "radio") { ProgramListView() }
            Tab("收藏", systemImage: "heart") { FavoritesView() }
            Tab("下載", systemImage: "arrow.down.circle") { DownloadsView() }
            Tab("AI", systemImage: "wand.and.stars") { AITabView() }
        }
        // Only let the tab bar collapse on scroll while the mini player is
        // showing (so the accessory slides inline, Apple Music style). With
        // nothing playing there's no accessory, so keep the tab bar fixed.
        .tabBarMinimizeBehavior(player.current != nil ? .onScrollDown : .never)
        .tabViewBottomAccessory(isEnabled: player.current != nil) {
            MiniPlayerAccessory { showPlayer = true }
        }
    }

    private var legacyTabs: some View {
        TabView {
            ProgramListView()
                .tabItem { Label("節目", systemImage: "radio") }
            FavoritesView()
                .tabItem { Label("收藏", systemImage: "heart") }
            DownloadsView()
                .tabItem { Label("下載", systemImage: "arrow.down.circle") }
            AITabView()
                .tabItem { Label("AI", systemImage: "wand.and.stars") }
        }
        // Float the mini player above the tab bar with an overlay:
        // safeAreaInset over a List doesn't receive touches reliably.
        .overlay(alignment: .bottom) {
            if player.current != nil {
                MiniPlayerBar { showPlayer = true }
                    .padding(.bottom, 49 + 8) // standard tab bar height + gap
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// The Mac sidebar's section switcher, styled after `GroupingToggle`: one
/// glass capsule split into equal segments, an accent capsule sliding to the
/// selection — not the stock segmented picker, which Catalyst renders as an
/// oversized iOS-style pill.
private struct MacTabBar: View {
    @Binding var selection: Int
    @Namespace private var ns

    private static let titles = ["節目", "收藏", "下載", "AI"]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.titles.enumerated()), id: \.offset) { index, title in
                let isSelected = selection == index
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .padding(3)
                            .matchedGeometryEffect(id: "indicator", in: ns)
                    }
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { selection = index } }
            }
        }
        .frame(height: 34)
        .modifier(CapsuleGlass())
    }
}
#endif

/// Content of the iOS 26 tab view bottom accessory. The system provides the
/// glass capsule background; when the tab bar collapses on scroll the
/// placement turns .inline and we drop the next button like Apple Music.
@available(iOS 26.0, *)
struct MiniPlayerAccessory: View {
    @EnvironmentObject var player: PlayerManager
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let onTap: () -> Void

    private var isInline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    CoverImage(urlString: player.current?.coverURL, size: isInline ? 30 : 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if !isInline {
                            Text(player.current?.programName ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            if !isInline {
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(!player.hasNext)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// Compact now-playing bar floated above the tab bar (pre-iOS 26 fallback).
struct MiniPlayerBar: View {
    @EnvironmentObject var player: PlayerManager
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    CoverImage(urlString: player.current?.coverURL, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(player.current?.programName ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(!player.hasNext)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12)
    }
}

/// Cover image with a music-note placeholder, backed by `CoverImageCache` so a
/// fetched cover persists on disk and is never re-downloaded across launches.
struct CoverImage: View {
    let urlString: String?
    var size: CGFloat

    @State private var image: UIImage?

    init(urlString: String?, size: CGFloat) {
        self.urlString = urlString
        self.size = size
        // Instant first paint when the cover is already in memory (no async hop).
        if let url = urlString.flatMap(URL.init(string:)) {
            _image = State(initialValue: CoverImageCache.shared.memoryCached(url))
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray5)
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
        .task(id: urlString) {
            guard let url = urlString.flatMap(URL.init(string:)) else { return }
            if let loaded = await CoverImageCache.shared.image(for: url), !Task.isCancelled {
                image = loaded
            }
        }
    }
}
