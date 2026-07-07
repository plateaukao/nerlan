import SwiftUI

/// Favorited programs and episodes.
struct FavoritesView: View {
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var player: PlayerManager

    private var groupedEpisodes: [(key: String, records: [EpisodeRecord])] {
        Dictionary(grouping: favorites.favorites, by: \.programName)
            .map { (key: $0.key, records: $0.value.sorted { ($0.playDate ?? "") < ($1.playDate ?? "") }) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if favorites.favorites.isEmpty && favorites.programs.isEmpty {
                    VStack(spacing: 0) {
                        TopTitle(text: "收藏")
                        ContentUnavailableView("沒有收藏",
                                               systemImage: "heart",
                                               description: Text("點選節目或單集旁的愛心即可加入收藏。"))
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    List {
                        ScrollAwayTitle(text: "收藏")
                        if !favorites.programs.isEmpty {
                            Section("節目") {
                                ForEach(favorites.programs) { program in
                                    NavigationLink(value: program) {
                                        ProgramRow(program: program)
                                    }
                                }
                                .onDelete { offsets in
                                    // Snapshot first: toggling mutates the live
                                    // array, which would shift later offsets.
                                    let doomed = offsets.map { favorites.programs[$0] }
                                    for program in doomed {
                                        favorites.toggle(program: program)
                                    }
                                }
                            }
                        }
                        ForEach(groupedEpisodes, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.records) { record in
                                    RecordRow(record: record, queue: group.records)
                                }
                                .onDelete { offsets in
                                    for i in offsets {
                                        favorites.toggle(group.records[i])
                                    }
                                }
                            }
                        }
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Program.self) { program in
                ProgramDetailView(program: program)
            }
        }
    }
}
