import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: PlayerManager
    @State private var showPlayer = false

    var body: some View {
        TabView {
            ProgramListView()
                .tabItem { Label("節目", systemImage: "radio") }
            FavoritesView()
                .tabItem { Label("收藏", systemImage: "heart") }
            DownloadsView()
                .tabItem { Label("下載", systemImage: "arrow.down.circle") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                MiniPlayerBar { showPlayer = true }
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
    }
}

/// Compact now-playing bar shown above the tab bar.
struct MiniPlayerBar: View {
    @EnvironmentObject var player: PlayerManager
    let onTap: () -> Void

    var body: some View {
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
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .disabled(!player.hasNext)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// Async cover image with a music-note placeholder.
struct CoverImage: View {
    let urlString: String?
    var size: CGFloat

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
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
    }
}
