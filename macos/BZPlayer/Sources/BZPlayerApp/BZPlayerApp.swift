import SwiftUI
import AppKit

// Debug logger
private let debugLogURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BZPlayer.log")
private func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: debugLogURL)
        }
    }
}

@main
struct BZPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsViewModel = PlayerViewModel()
    @StateObject private var fileInfoViewModel = FileInfoViewModel()

    var body: some Scene {
        Window("BZPlayer", id: "main") {
            PlayerWindowRootView(appDelegate: appDelegate, fileInfoViewModel: fileInfoViewModel)
        }
        .windowResizability(.contentMinSize)
        // 阻止 SwiftUI 自动为外部事件（如文件打开）创建新窗口
        // 我们通过 AppDelegate 统一手动调度到已有窗口
        .handlesExternalEvents(matching: Set(["*"]))

        Settings {
            SettingsView(viewModel: settingsViewModel)
        }
    }
}

private struct PlayerWindowRootView: View {
    let appDelegate: AppDelegate
    @ObservedObject var fileInfoViewModel: FileInfoViewModel
    @StateObject private var viewModel = PlayerViewModel()
    @State private var windowNumber: Int?

    var body: some View {
        PlayerRootView()
            .environmentObject(viewModel)
            .frame(minWidth: 980, minHeight: 620)
            .background(
                WindowAccessor { window in
                    windowNumber = window.windowNumber
                    viewModel.attachWindow(window)
                    appDelegate.register(window: window, viewModel: viewModel)
                    appDelegate.setActiveViewModel(viewModel)
                }
            )
            .onAppear {
                viewModel.refreshPreferences()
                appDelegate.setActiveViewModel(viewModel)
                appDelegate.consumePendingURLsIfNeeded(using: viewModel)
                viewModel.onShowFileInfo = { content in
                    fileInfoViewModel.content = content
                    fileInfoViewModel.showPanel()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let window = notification.object as? NSWindow else { return }
                guard window.windowNumber == windowNumber else { return }
                viewModel.attachWindow(window)
                appDelegate.setActiveViewModel(viewModel)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSWindow else { return }
                guard window.windowNumber == windowNumber else { return }
                viewModel.prepareForWindowClose()
                appDelegate.unregister(window: window)
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                viewModel.refreshPreferences()
            }
            .onReceive(viewModel.$openedFilePath) { _ in
                appDelegate.rerouteIfMultipleWindowsDisabled(source: viewModel)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingURLs: [URL] = []
    private weak var activeViewModel: PlayerViewModel?
    private var extraWindowControllers: [NSWindowController] = []
    private var extraWindowCloseObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var registeredWindows: [ObjectIdentifier: WeakWindowBinding] = [:]
    private var fallbackCreateWindowTask: DispatchWorkItem?
    private var isReroutingOpen = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        debugLog("[AppDelegate] openFile called: \(filename), registeredWindows count: \(registeredWindows.count)")

        // If there's an existing window, use it to play the file
        if let targetBinding = singleWindowTargetBinding() {
            debugLog("[AppDelegate] Found existing window, reusing it")
            let vm = targetBinding.viewModel
            let window = targetBinding.window
            DispatchQueue.main.async {
                vm?.openExternalFiles([url])
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return true
        }
        // No existing window, create a new one
        debugLog("[AppDelegate] No existing window found, creating new window")
        DispatchQueue.main.async {
            self.pendingURLs = [url]
            self.createAdditionalPlayerWindow()
        }
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        // If there's an existing window, use it to play the files
        if let targetBinding = singleWindowTargetBinding() {
            let vm = targetBinding.viewModel
            let window = targetBinding.window
            DispatchQueue.main.async {
                vm?.openExternalFiles(urls)
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        // No existing window, create a new one
        DispatchQueue.main.async {
            self.pendingURLs = urls
            self.createAdditionalPlayerWindow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Always reuse existing window if available, regardless of allowMultipleWindows setting.
            // "Allow multiple windows" only affects intentional multi-window usage, not Finder open.
            if let targetBinding = self.singleWindowTargetBinding() {
                targetBinding.viewModel?.openExternalFiles(urls)
                // 如果窗口已经显示，只在必要时才 orderFront，减少闪烁
                if targetBinding.window?.isKeyWindow == false {
                    targetBinding.window?.makeKeyAndOrderFront(nil)
                }
            } else if let activeViewModel = self.activeViewModel {
                activeViewModel.openExternalFiles(urls)
            } else {
                // No window exists at all, store pending and create one
                self.pendingURLs = urls
                self.scheduleFallbackWindowCreationIfNeeded()
            }
            // 只有当程序不在前台时才激活，减少抢占感
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    @MainActor
    func consumePendingURLsIfNeeded(using viewModel: PlayerViewModel) {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        fallbackCreateWindowTask?.cancel()
        viewModel.openExternalFiles(urls)
    }

    @MainActor
    func setActiveViewModel(_ viewModel: PlayerViewModel) {
        activeViewModel = viewModel
    }

    @MainActor
    func register(window: NSWindow, viewModel: PlayerViewModel) {
        let key = ObjectIdentifier(window)
        registeredWindows[key] = WeakWindowBinding(window: window, viewModel: viewModel)
        cleanupDeadWindowBindings()
        debugLog("[AppDelegate] Window registered, windowNumber: \(window.windowNumber), total registered: \(registeredWindows.count)")
    }

    @MainActor
    func unregister(window: NSWindow) {
        registeredWindows.removeValue(forKey: ObjectIdentifier(window))
        cleanupDeadWindowBindings()
    }

    @MainActor
    func rerouteIfMultipleWindowsDisabled(source: PlayerViewModel) {
        guard !isReroutingOpen else { return }
        guard shouldAllowMultipleWindows() == false else { return }
        cleanupDeadWindowBindings()

        guard registeredWindows.count > 1 else { return }

        if let targetBinding = self.singleWindowTargetBinding(excluding: source) {
            isReroutingOpen = true

            if let newURL = source.currentMediaURL {
                targetBinding.viewModel?.openExternalFiles([newURL])
            }

            if let targetVM = targetBinding.viewModel {
                setActiveViewModel(targetVM)
                targetBinding.window?.makeKeyAndOrderFront(nil)
            }

            DispatchQueue.main.async { [weak self, weak source] in
                guard let window = source?.currentWindow else { return }
                window.close()
                self?.isReroutingOpen = false
            }
        }
    }

    @MainActor
    private func shouldAllowMultipleWindows() -> Bool {
        UserDefaults.standard.object(forKey: "settings.allowMultipleWindows") as? Bool ?? true
    }

    private func createAdditionalPlayerWindow() {
        debugLog("[AppDelegate] Creating additional player window")
        let fileInfoViewModel = FileInfoViewModel()
        let host = NSHostingController(rootView: PlayerWindowRootView(appDelegate: self, fileInfoViewModel: fileInfoViewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "BZPlayer"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 980, height: 620))
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        extraWindowControllers.append(controller)
        let windowID = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak controller, weak window] _ in
            guard let self else { return }
            if let window {
                self.extraWindowCloseObservers.removeValue(forKey: ObjectIdentifier(window)).map {
                    NotificationCenter.default.removeObserver($0)
                }
            }
            if let controller {
                self.extraWindowControllers.removeAll { $0 === controller }
            }
        }
        extraWindowCloseObservers[windowID] = observer
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func scheduleFallbackWindowCreationIfNeeded() {
        fallbackCreateWindowTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.pendingURLs.isEmpty else { return }
            self.createAdditionalPlayerWindow()
        }
        fallbackCreateWindowTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    @MainActor
    private func deactivateOtherPlayerWindows(excludingWindow activeWindow: NSWindow?) {
        cleanupDeadWindowBindings()
        for (_, binding) in registeredWindows {
            guard let window = binding.window, let viewModel = binding.viewModel else { continue }
            guard window !== activeWindow else { continue }
            viewModel.prepareForWindowClose()
            window.orderOut(nil)
        }
    }

    @MainActor
    private func singleWindowTargetBinding(excluding excludedViewModel: PlayerViewModel? = nil) -> WeakWindowBinding? {
        cleanupDeadWindowBindings()
        debugLog("[AppDelegate] singleWindowTargetBinding called, registeredWindows: \(registeredWindows.count), keyWindow: \(NSApp.keyWindow != nil), mainWindow: \(NSApp.mainWindow != nil), activeViewModel: \(activeViewModel != nil)")

        // First, try to find any valid binding from registeredWindows
        if let binding = registeredWindows.values.first(where: { $0.viewModel !== excludedViewModel && $0.window != nil && $0.viewModel != nil }) {
            debugLog("[AppDelegate] Found valid binding from registeredWindows, windowNumber: \(binding.window?.windowNumber ?? -1)")
            return binding
        }

        // Fall back to keyWindow/mainWindow check
        if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow,
           let binding = registeredWindows[ObjectIdentifier(keyWindow)],
           let viewModel = binding.viewModel,
           viewModel !== excludedViewModel {
            debugLog("[AppDelegate] Found binding via key/main window")
            return binding
        }

        // Fall back to activeViewModel
        if let activeViewModel, activeViewModel !== excludedViewModel,
           let binding = registeredWindows.values.first(where: { $0.viewModel === activeViewModel }) {
            debugLog("[AppDelegate] Found binding via activeViewModel")
            return binding
        }

        debugLog("[AppDelegate] No binding found")
        return nil
    }

    private func cleanupDeadWindowBindings() {
        registeredWindows = registeredWindows.filter { _, binding in
            binding.window != nil && binding.viewModel != nil
        }
    }
}

private final class WeakWindowBinding {
    weak var window: NSWindow?
    weak var viewModel: PlayerViewModel?

    init(window: NSWindow, viewModel: PlayerViewModel) {
        self.window = window
        self.viewModel = viewModel
    }
}