import SwiftUI

@main
struct NerLanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PlayerManager.shared)
                .environmentObject(DownloadManager.shared)
                .environmentObject(FavoritesStore.shared)
        }
    }
}
