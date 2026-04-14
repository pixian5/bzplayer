import SwiftUI
import AppKit

@main
struct BZPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = PlayerViewModel()

    var body: some Scene {
        WindowGroup {
            PlayerRootView()
                .environmentObject(viewModel)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    appDelegate.consumePendingURLsIfNeeded(using: viewModel)
                }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openFilesNotification)) { notification in
                    guard let urls = notification.object as? [URL], !urls.isEmpty else { return }
                    viewModel.openExternalFiles(urls)
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(viewModel: viewModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openFilesNotification = Notification.Name("BZPlayerOpenFilesNotification")
    private var pendingURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs = urls
        NotificationCenter.default.post(name: Self.openFilesNotification, object: urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func consumePendingURLsIfNeeded(using viewModel: PlayerViewModel) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        viewModel.openExternalFiles(urls)
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.title3)
                .fontWeight(.semibold)

            Text("可通过 ⌘, 打开本页。")
                .foregroundStyle(.secondary)

            Button("关联常见视频格式") {
                viewModel.associateCommonVideoFormats()
            }

            Text(viewModel.fileAssociationStatus)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(16)
        .frame(width: 420, height: 220)
    }
}
