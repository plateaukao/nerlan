import SwiftUI

@main
struct NerLanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .appEnvironment()
        }
    }
}

extension View {
    /// Inject every shared app store. SwiftUI normally flows environment objects
    /// from an ancestor into a presented `.sheet`/`.fullScreenCover`, but the Mac
    /// "Designed for iPad" presentation bridge does **not** — a sheet root there
    /// renders with an empty environment and crashes with "No ObservableObject of
    /// type … found". So this is applied both at the window root and at every sheet
    /// root; re-injecting the same singletons is idempotent and harmless on iOS.
    func appEnvironment() -> some View {
        self
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
