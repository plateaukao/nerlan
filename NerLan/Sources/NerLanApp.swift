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
    #if targetEnvironment(macCatalyst)
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    #endif

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
            CommandGroup(after: .sidebar) {
                Button(sidebarHidden ? "顯示側欄" : "隱藏側欄") { sidebarHidden.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// The Mac window titlebar toolbar: a single sidebar-toggle button sitting on
/// the traffic-light row, always visible whatever tab or panel is showing.
/// SwiftUI can't place controls there on Catalyst, so this is the AppKit
/// bridge; the button just flips the `sidebarHidden` default that
/// ContentView's split layout observes.
final class MacToolbar: NSObject, NSToolbarDelegate {
    static let shared = MacToolbar()
    private static let toggleSidebar = NSToolbarItem.Identifier("toggleSidebar")

    /// Idempotent; called from ContentView.onAppear once the scene exists.
    func attach(to scene: UIWindowScene) {
        guard let titlebar = scene.titlebar, titlebar.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "NerLanMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        titlebar.toolbar = toolbar
        titlebar.toolbarStyle = .unifiedCompact
        titlebar.titleVisibility = .hidden
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.toggleSidebar else { return nil }
        let button = UIBarButtonItem(image: UIImage(systemName: "sidebar.leading"),
                                     style: .plain, target: self, action: #selector(toggle))
        let item = NSToolbarItem(itemIdentifier: itemIdentifier, barButtonItem: button)
        item.label = "側欄"
        item.toolTip = "顯示或隱藏側欄"
        return item
    }

    @objc private func toggle() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "sidebarHidden"), forKey: "sidebarHidden")
    }
}
#endif

extension Notification.Name {
    /// Posted by the Mac "設定…" menu command; observed by ProgramListView.
    static let openSettings = Notification.Name("com.danielkao.NerLan.openSettings")
    /// Posted by the Mac sidebar header's + button; observed by ProgramListView,
    /// which owns the Add Podcast sheet.
    static let addPodcast = Notification.Name("com.danielkao.NerLan.addPodcast")
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
