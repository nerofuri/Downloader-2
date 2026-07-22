import SwiftUI
import AVFoundation

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        AdBlocker.shared.prepare()
        return true
    }

    // Called when background downloads finish while the app is suspended.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandlers[identifier] = completionHandler
        _ = DownloadManager.shared.session
        _ = DownloadManager.shared.assetSession
    }
}

@main
struct Downloader2App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tabManager = TabManager()
    @StateObject private var downloads = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(tabManager)
                .environmentObject(downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .background(Theme.bg)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                tabManager.persistSession()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var tabManager: TabManager

    var body: some View {
        Group {
            if let tab = tabManager.activeTab {
                BrowserScreen(tab: tab)
                    .id(tab.id)
            } else {
                Color(.systemBackground).onAppear { tabManager.newTab() }
            }
        }
    }
}
