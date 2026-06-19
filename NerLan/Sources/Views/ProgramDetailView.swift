import SwiftUI

/// Program info plus its full episode archive (paginated, oldest first).
struct ProgramDetailView: View {
    let program: Program

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore

    @State private var episodes: [Episode] = []
    @State private var page = 0
    @State private var totalPages = 1
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var showFullIntro = false

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
            }

            Section {
                if episodes.isEmpty && isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if episodes.isEmpty {
                    Text("沒有單集")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode,
                                   record: record(for: episode),
                                   queue: episodes.map(record(for:)))
                            .onAppear {
                                // infinite scroll: fetch the next page near the end
                                if episode.id == episodes.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                    }
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                Text(totalCount > 0 ? "單集列表（共 \(totalCount) 集）" : "單集列表")
            }
        }
        .listStyle(.plain)
        .refreshable { await refresh() }
        // The header shows the program name next to the cover, so don't repeat it
        // as the nav-bar title.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    favorites.toggle(program: program)
                } label: {
                    Image(systemName: favorites.isFavorite(programId: program.programId) ? "heart.fill" : "heart")
                        .foregroundStyle(.pink)
                }
            }
        }
        .task { await loadInitial() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(urlString: program.coverURL?.absoluteString, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.name)
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(program.language)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                        if let level = program.level {
                            Text(level)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let count = program.episodeCount {
                        Text("共 \(count) 集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            let intro = program.descriptionText
            if !intro.isEmpty {
                Text(intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullIntro ? nil : 3)
                    .onTapGesture { showFullIntro.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    /// On first appearance, restore the cached episode pages if we have them (no
    /// network); otherwise fetch the first page. Infinite scroll then resumes from
    /// the cached cursor, so previously-seen pages are never re-fetched.
    private func loadInitial() async {
        guard episodes.isEmpty else { return }
        if let cached = CatalogCache.loadEpisodes(programId: program.programId), !cached.episodes.isEmpty {
            episodes = cached.episodes
            page = cached.page
            totalPages = cached.totalPages
            totalCount = cached.totalCount
            return
        }
        await loadMore()
    }

    private func loadMore() async {
        guard !isLoading, page < totalPages || page == 0 else { return }
        isLoading = true
        do {
            let next = page + 1
            let result = try await ChannelPlusAPI.episodes(programId: program.programId, page: next)
            let known = Set(episodes.map(\.id))
            episodes += result.episodes.filter { !known.contains($0.id) }
            page = next
            totalPages = result.totalPages
            totalCount = result.totalCount
            saveCache()
        } catch {
            // keep what we have; retry happens on next scroll (or pull-to-refresh)
        }
        isLoading = false
    }

    /// Pull-to-refresh: re-fetch the program from the first page, replacing the
    /// cache. Episodes are ascending (oldest first), so a higher `totalCount`
    /// surfaces newly-added episodes as the user scrolls back down.
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            let result = try await ChannelPlusAPI.episodes(programId: program.programId, page: 1)
            episodes = result.episodes
            page = 1
            totalPages = result.totalPages
            totalCount = result.totalCount
            saveCache()
        } catch {
            // keep what we have on a failed refresh
        }
        isLoading = false
    }

    private func saveCache() {
        CatalogCache.saveEpisodes(
            .init(episodes: episodes, page: page, totalPages: totalPages, totalCount: totalCount),
            programId: program.programId)
    }

    private func record(for episode: Episode) -> EpisodeRecord {
        EpisodeRecord(episode: episode,
                      programId: program.programId,
                      programName: program.name,
                      language: program.language,
                      coverURL: (ChannelPlusAPI.imageURL(episode.image?.imageRef) ?? program.coverURL)?.absoluteString)
    }
}

/// One episode row with play / favorite / download actions.
struct EpisodeRow: View {
    let episode: Episode
    let record: EpisodeRecord
    let queue: [EpisodeRecord]

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore

    private var isCurrent: Bool { player.current?.id == episode.id }
    private var playable: Bool { episode.audioURL != nil }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard playable else { return }
                if isCurrent {
                    player.togglePlayPause()
                } else {
                    player.play(record, in: queue)
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            if let n = episode.episodeNumber {
                                Text("EP\(n)")
                            }
                            Text(episode.releaseDateText)
                            if !episode.durationText.isEmpty {
                                Text(episode.durationText)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playable)

            Button {
                favorites.toggle(record)
            } label: {
                Image(systemName: favorites.isFavorite(episodeId: episode.id) ? "heart.fill" : "heart")
                    .foregroundStyle(.pink)
            }
            .buttonStyle(.borderless)

            downloadButton
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if downloads.isDownloaded(episodeId: episode.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if downloads.isDownloading(episodeId: episode.id) {
            ProgressView()
                .progressViewStyle(.circular)
        } else {
            Button {
                downloads.download(record)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!playable)
        }
    }
}
