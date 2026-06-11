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
                    ContentUnavailableView("沒有收藏",
                                           systemImage: "heart",
                                           description: Text("點選節目或單集旁的愛心即可加入收藏。"))
                } else {
                    List {
                        if !favorites.programs.isEmpty {
                            Section("節目") {
                                ForEach(favorites.programs) { program in
                                    NavigationLink(value: program) {
                                        ProgramRow(program: program)
                                    }
                                }
                                .onDelete { offsets in
                                    for i in offsets {
                                        favorites.toggle(program: favorites.programs[i])
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
                }
            }
            .navigationTitle("收藏")
            .navigationDestination(for: Program.self) { program in
                ProgramDetailView(program: program)
            }
        }
    }
}
