import SwiftUI

/// Receives the background-download wake-up: when the app was killed while a
/// background URLSession download ran, the system relaunches it and calls
/// `handleEventsForBackgroundURLSession`. Touching `DownloadManager.shared`
/// recreates the session under the same identifier, which is what lets its
/// delegate receive the queued events; the completion handler is stored and
/// invoked from `urlSessionDidFinishEvents` once they've all been delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct NerLanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .appEnvironment()
        }
        #if targetEnvironment(macCatalyst)
        // On Mac, surface Settings as the standard app-menu item (⌘,) rather than a
        // toolbar gear (hidden on Catalyst). The command signals ProgramListView,
        // which owns the Settings sheet.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    /// Posted by the Mac "設定…" menu command; observed by ProgramListView.
    static let openSettings = Notification.Name("com.danielkao.NerLan.openSettings")
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
