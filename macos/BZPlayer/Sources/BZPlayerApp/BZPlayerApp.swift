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
    @State private var seekSecondsText = ""
    @State private var frameStepText = ""

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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("快捷键")
                    .font(.headline)

                HStack {
                    Text("左右方向键跳转秒数")
                        .frame(width: 150, alignment: .leading)
                    TextField("秒数", text: $seekSecondsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(applyShortcutSettings)
                    Stepper("", value: Binding(
                        get: { viewModel.shortcutSeekSeconds },
                        set: { viewModel.setShortcutSeekSeconds($0) }
                    ), in: 0.5...60, step: 0.5)
                    .labelsHidden()
                }

                HStack {
                    Text("上下方向键跳转帧数")
                        .frame(width: 150, alignment: .leading)
                    TextField("帧数", text: $frameStepText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit(applyShortcutSettings)
                    Stepper("", value: Binding(
                        get: { viewModel.shortcutFrameStepCount },
                        set: { viewModel.setShortcutFrameStepCount($0) }
                    ), in: 1...240, step: 1)
                    .labelsHidden()
                }

                Text("左/右：按设定秒数后退/前进；上/下：按设定帧数后退/前进。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 460, height: 320)
        .onAppear {
            syncShortcutFields()
        }
        .onChange(of: viewModel.shortcutSeekSeconds) { _ in
            syncShortcutFields()
        }
        .onChange(of: viewModel.shortcutFrameStepCount) { _ in
            syncShortcutFields()
        }
    }

    private func syncShortcutFields() {
        seekSecondsText = String(format: "%.1f", viewModel.shortcutSeekSeconds)
        frameStepText = "\(viewModel.shortcutFrameStepCount)"
    }

    private func applyShortcutSettings() {
        if let seek = Double(seekSecondsText) {
            viewModel.setShortcutSeekSeconds(seek)
        } else {
            seekSecondsText = String(format: "%.1f", viewModel.shortcutSeekSeconds)
        }

        if let frames = Int(frameStepText) {
            viewModel.setShortcutFrameStepCount(frames)
        } else {
            frameStepText = "\(viewModel.shortcutFrameStepCount)"
        }
    }
}
