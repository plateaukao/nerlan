import SwiftUI

@main
struct NerLanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(PlayerManager.shared)
                .environmentObject(DownloadManager.shared)
                .environmentObject(FavoritesStore.shared)
                .environmentObject(PodcastStore.shared)
                .environmentObject(SettingsStore.shared)
                .environmentObject(AIContentStore.shared)
                .environmentObject(StudyPanel.shared)
                .environmentObject(ListeningStatsStore.shared)
                .environmentObject(DriveSync.shared)
        }
    }
}
