import SwiftUI
import AppKit

@main
struct BZPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settingsViewModel = PlayerViewModel()

    var body: some Scene {
        Window("BZPlayer", id: "main") {
            PlayerWindowRootView(appDelegate: appDelegate)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(viewModel: settingsViewModel)
        }
    }
}

private struct PlayerWindowRootView: View {
    let appDelegate: AppDelegate
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
        if !shouldAllowMultipleWindows() {
            if let targetBinding = singleWindowTargetBinding() {
                let vm = targetBinding.viewModel
                let window = targetBinding.window
                DispatchQueue.main.async {
                    vm?.openExternalFiles([url])
                    window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                return true
            }
        } else {
            DispatchQueue.main.async {
                self.pendingURLs = [url]
                self.createAdditionalPlayerWindow()
            }
            return true
        }
        return false
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if !shouldAllowMultipleWindows() {
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
        } else {
            DispatchQueue.main.async {
                self.pendingURLs = urls
                self.createAdditionalPlayerWindow()
            }
            return
        }
        self.application(NSApp, open: urls)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if self.shouldAllowMultipleWindows(), self.activeViewModel != nil {
                self.pendingURLs = urls
                self.scheduleFallbackWindowCreationIfNeeded()
            } else if let activeViewModel = self.activeViewModel {
                activeViewModel.openExternalFiles(urls)
            } else {
                self.pendingURLs = urls
            }
            NSApp.activate(ignoringOtherApps: true)
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
        let host = NSHostingController(rootView: PlayerWindowRootView(appDelegate: self))
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

        if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow,
           let binding = registeredWindows[ObjectIdentifier(keyWindow)],
           let viewModel = binding.viewModel,
           viewModel !== excludedViewModel {
            return binding
        }

        if let activeViewModel, activeViewModel !== excludedViewModel,
           let binding = registeredWindows.values.first(where: { $0.viewModel === activeViewModel }) {
            return binding
        }

        return registeredWindows.values.first { $0.viewModel !== excludedViewModel }
    }

    private func cleanupDeadWindowBindings() {
        registeredWindows = registeredWindows.filter { _, binding in
            binding.window != nil && binding.viewModel != nil
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var seekSecondsText = ""
    @State private var frameStepText = ""
    @State private var audioDelayStepMsText = ""

    var body: some View {
        ScrollView {
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

                    HStack {
                        Text("上一文件快捷键")
                            .frame(width: 150, alignment: .leading)
                        Text("上一")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.previousFileKeyCode) },
                            set: { viewModel.setPreviousFileKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                        Text("下一")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.nextFileKeyCode) },
                            set: { viewModel.setNextFileKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    Text("默认上一文件是 `[`，下一文件是 `]`，按物理键位处理，不受中英文输入影响。速度调节为 `;` 和 `'`。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("音频步进快捷键")
                            .frame(width: 150, alignment: .leading)
                        Text("减小")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.audioStepDownKeyCode) },
                            set: { viewModel.setAudioStepDownKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                        Text("增加")
                        Picker("", selection: Binding(
                            get: { Int(viewModel.audioStepUpKeyCode) },
                            set: { viewModel.setAudioStepUpKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    HStack {
                        Text("倍速切换快捷键")
                            .frame(width: 150, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { Int(viewModel.speedToggleKeyCode) },
                            set: { viewModel.setSpeedToggleKeyCode(UInt16($0)) }
                        )) {
                            ForEach(keyShortcutOptions, id: \.keyCode) { option in
                                Text(option.label).tag(Int(option.keyCode))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 72)
                    }

                    Text("默认音频步进为 `,` 和 `.`，倍速切换为 `=`，按物理键位处理。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("打开文件时窗口")
                            .frame(width: 150, alignment: .leading)
                        Picker("打开文件时窗口", selection: Binding(
                            get: { viewModel.windowOpenBehavior },
                            set: { viewModel.setWindowOpenBehavior($0) }
                        )) {
                            ForEach(PlayerViewModel.WindowOpenBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    Text("默认最大化。尽量大表示按视频比例尽可能铺满屏幕可视区域，不强行加黑边占满。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Toggle("允许多窗口", isOn: Binding(
                        get: { viewModel.allowMultipleWindows },
                        set: { viewModel.setAllowMultipleWindows($0) }
                    ))
                    .toggleStyle(.checkbox)

                    Text("关闭后，新打开的文件会直接在当前窗口播放，不另开新窗口。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("音频延迟步进")
                            .frame(width: 150, alignment: .leading)
                        TextField("ms", text: $audioDelayStepMsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyAudioDelayStepMs)
                        Stepper("", value: Binding(
                            get: { viewModel.audioDelayStepMs },
                            set: { viewModel.setAudioDelayStepMs($0) }
                        ), in: 1...500, step: 10)
                        .labelsHidden()
                        Text("ms")
                    }

                    Text("音频延迟步进决定每次按音频步进快捷键时延迟的增减量，每个文件的延迟值独立记忆。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 550, height: 520)
        .onAppear {
            syncShortcutFields()
            syncAudioDelayStepField()
        }
        .onChange(of: viewModel.shortcutSeekSeconds) { _ in
            syncShortcutFields()
        }
        .onChange(of: viewModel.shortcutFrameStepCount) { _ in
            syncShortcutFields()
        }
        .onChange(of: viewModel.audioDelayStepMs) { _ in
            syncAudioDelayStepField()
        }
    }

    private func syncShortcutFields() {
        seekSecondsText = String(format: "%.1f", viewModel.shortcutSeekSeconds)
        frameStepText = "\(viewModel.shortcutFrameStepCount)"
    }

    private func syncAudioDelayStepField() {
        audioDelayStepMsText = String(format: "%.0f", viewModel.audioDelayStepMs)
    }

    private func applyAudioDelayStepMs() {
        if let step = Double(audioDelayStepMsText), step >= 1 {
            viewModel.setAudioDelayStepMs(step)
        } else {
            audioDelayStepMsText = String(format: "%.0f", viewModel.audioDelayStepMs)
        }
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

    private var keyShortcutOptions: [KeyShortcutOption] {
        [
            .init(label: ";", keyCode: 41),
            .init(label: "'", keyCode: 39),
            .init(label: ",", keyCode: 43),
            .init(label: ".", keyCode: 47),
            .init(label: "/", keyCode: 44),
            .init(label: "[", keyCode: 33),
            .init(label: "]", keyCode: 30),
            .init(label: "-", keyCode: 27),
            .init(label: "=", keyCode: 24),
            .init(label: "\\", keyCode: 42)
        ]
    }
}

private struct KeyShortcutOption {
    let label: String
    let keyCode: UInt16
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveWindowIfNeeded()
    }
}

private final class WindowAccessorView: NSView {
    var onResolve: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolveWindowIfNeeded()
    }

    func resolveWindowIfNeeded() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.onResolve?(window)
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