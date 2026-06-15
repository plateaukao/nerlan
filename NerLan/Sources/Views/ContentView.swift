import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var ai: AIContentStore
    @EnvironmentObject var study: StudyPanel
    @State private var showPlayer = false

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
            legacyTabs
                .frame(width: 390)
            Divider()
            StudyDetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // When a new episode starts, default the panel to its study content,
        // preferring a PDF handout, then the AI handout, then the transcript.
        .onChange(of: player.current) { _, record in
            showDefaultStudy(for: record)
        }
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
        .tabBarMinimizeBehavior(.onScrollDown)
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
