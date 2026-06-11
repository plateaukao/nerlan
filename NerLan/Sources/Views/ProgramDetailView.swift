import SwiftUI

/// Program info plus its episodes, browsable by month.
struct ProgramDetailView: View {
    let program: Program

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var favorites: FavoritesStore

    @State private var info: ProgramInfo?
    @State private var episodes: [Episode] = []
    @State private var year: Int
    @State private var month: Int
    @State private var isLoading = false
    @State private var showFullIntro = false

    init(program: Program) {
        self.program = program
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        _year = State(initialValue: now.year ?? 2026)
        _month = State(initialValue: now.month ?? 1)
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
            }

            Section {
                monthPicker
                    .listRowSeparator(.hidden)

                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if episodes.isEmpty {
                    Text("本月沒有單集")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode,
                                   record: record(for: episode),
                                   queue: episodes.map(record(for:)))
                    }
                }
            } header: {
                Text("單集列表")
            }
        }
        .listStyle(.plain)
        .navigationTitle(program.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            info = try? await NERAPI.programInfo(id: program.id)
            await loadEpisodes()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CoverImage(urlString: info?.cover ?? program.cover, size: 88)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info?.name ?? program.name)
                        .font(.headline)
                    if let en = info?.englishName {
                        Text(en).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(program.scheduleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let hosts = info?.hosts, !hosts.isEmpty {
                        Text("主持：" + hosts.map(\.name).joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let intro = info?.introductionText, !intro.isEmpty {
                Text(intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullIntro ? nil : 3)
                    .onTapGesture { showFullIntro.toggle() }
            }
        }
        .padding(.vertical, 4)
    }

    private var monthPicker: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(String(format: "%d 年 %d 月", year, month))
                .font(.subheadline.weight(.medium))
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .disabled(isCurrentMonth)
        }
        .buttonStyle(.borderless)
    }

    private var isCurrentMonth: Bool {
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        return year == now.year && month == now.month
    }

    private func shiftMonth(_ delta: Int) {
        var m = month + delta
        var y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        (year, month) = (y, m)
        Task { await loadEpisodes() }
    }

    private func loadEpisodes() async {
        isLoading = true
        episodes = (try? await NERAPI.episodes(programId: program.id, year: year, month: month)) ?? []
        isLoading = false
    }

    private func record(for episode: Episode) -> EpisodeRecord {
        EpisodeRecord(episode: episode,
                      programName: info?.name ?? program.name,
                      language: program.language ?? "",
                      coverURL: info?.cover ?? program.cover)
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
                    Image(systemName: isCurrent && player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(playable ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(2)
                        Text(episode.playDateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
        } else if let p = downloads.progress[episode.id] {
            ProgressView(value: p)
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
