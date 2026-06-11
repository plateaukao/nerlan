import SwiftUI

/// Favorited episodes grouped by program.
struct FavoritesView: View {
    @EnvironmentObject var favorites: FavoritesStore
    @EnvironmentObject var player: PlayerManager

    private var grouped: [(key: String, records: [EpisodeRecord])] {
        Dictionary(grouping: favorites.favorites, by: \.programName)
            .map { (key: $0.key, records: $0.value.sorted { ($0.playDate ?? "") < ($1.playDate ?? "") }) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            Group {
                if favorites.favorites.isEmpty {
                    ContentUnavailableView("沒有收藏的單集",
                                           systemImage: "heart",
                                           description: Text("點選單集旁的愛心即可加入收藏。"))
                } else {
                    List {
                        ForEach(grouped, id: \.key) { group in
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
        }
    }
}
