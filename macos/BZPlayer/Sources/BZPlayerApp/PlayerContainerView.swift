import AppKit
import AVKit
import SwiftUI
import VLCKitSPM

struct PlayerContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.clickView.onSingleClick = {
            viewModel.togglePause()
        }
        view.clickView.onDoubleClick = {
            viewModel.toggleFullscreen(in: view.window)
        }
        view.clickView.onRequestFileInfo = {
            viewModel.showFileInfo()
        }
        view.clickView.onBuildSubtitleMenuEntries = {
            viewModel.subtitleMenuEntries()
        }
        view.clickView.onSelectSubtitleByPath = { path in
            viewModel.selectSubtitle(path: path)
        }
        view.clickView.onSetSubtitleBackgroundOpacity = { opacity in
            viewModel.setSubtitleBackgroundOpacity(opacity)
        }
        view.clickView.onCurrentSubtitleBackgroundOpacity = {
            viewModel.subtitleBackgroundOpacity
        }
        view.clickView.onSetSubtitleFontSize = { size in
            viewModel.setSubtitleFontSize(size)
        }
        view.clickView.onCurrentSubtitleFontSize = {
            viewModel.subtitleFontSize
        }
        view.clickView.onBuildAudioTrackMenuEntries = {
            viewModel.audioTrackMenuEntries()
        }
        view.clickView.onSelectAudioTrack = { id in
            viewModel.selectAudioTrack(id: id)
        }
        view.clickView.onBuildEmbeddedSubtitleMenuEntries = {
            viewModel.embeddedSubtitleMenuEntries()
        }
        view.clickView.onSelectEmbeddedSubtitle = { id in
            viewModel.selectEmbeddedSubtitle(id: id)
        }
        view.clickView.onKeyEvent = { [weak view, weak viewModel] event in
            guard let viewModel = viewModel else { return false }
            return InputDispatcher(viewModel: viewModel).handleKeyEvent(event, in: view?.window)
        }
        view.clickView.onSpeedKeyDown = { delta in
            viewModel.adjustSpeed(by: delta)
        }
        view.clickView.onSpeedKeyUp = {
            // 不需要额外操作
        }
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.updateBackend(
            viewModel.playbackBackend,
            player: viewModel.nativePlayer,
            nativeRefreshID: viewModel.nativePlayerSurfaceRefreshID
        )
        if nsView.window != nil {
            if viewModel.playbackBackend == .vlc {
                viewModel.attachVLCView(nsView.vlcVideoView)
            }
        }
    }
}

final class PlayerHostView: NSView {
    let nativePlayerView = AVPlayerView()
    let vlcVideoView = VLCVideoView(frame: .zero)
    let clickView = ClickCaptureView()
    private var lastNativeRefreshID = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        nativePlayerView.translatesAutoresizingMaskIntoConstraints = false
        nativePlayerView.controlsStyle = .none
        nativePlayerView.videoGravity = .resizeAspect
        nativePlayerView.showsFullScreenToggleButton = false
        nativePlayerView.player = nil

        vlcVideoView.translatesAutoresizingMaskIntoConstraints = false
        vlcVideoView.isHidden = true
        clickView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nativePlayerView)
        addSubview(vlcVideoView)
        addSubview(clickView)

        NSLayoutConstraint.activate([
            nativePlayerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativePlayerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativePlayerView.topAnchor.constraint(equalTo: topAnchor),
            nativePlayerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            vlcVideoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vlcVideoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vlcVideoView.topAnchor.constraint(equalTo: topAnchor),
            vlcVideoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clickView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickView.topAnchor.constraint(equalTo: topAnchor),
            clickView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBackend(_ backend: PlayerViewModel.PlaybackBackend, player: AVPlayer, nativeRefreshID: Int) {
        switch backend {
        case .native:
            if nativePlayerView.player !== player {
                nativePlayerView.player = player
            } else if nativeRefreshID != lastNativeRefreshID {
                nativePlayerView.player = nil
                nativePlayerView.player = player
            }
            lastNativeRefreshID = nativeRefreshID
            nativePlayerView.isHidden = false
            vlcVideoView.isHidden = true
        case .vlc:
            nativePlayerView.player = nil
            nativePlayerView.isHidden = true
            vlcVideoView.isHidden = false
        }
    }
}

final class ClickCaptureView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRequestFileInfo: (() -> Void)?
    var onBuildSubtitleMenuEntries: (() -> [PlayerViewModel.SubtitleMenuEntry])?
    var onSelectSubtitleByPath: ((String?) -> Void)?
    var onSetSubtitleBackgroundOpacity: ((Int) -> Void)?
    var onCurrentSubtitleBackgroundOpacity: (() -> Int)?
    var onSetSubtitleFontSize: ((Int) -> Void)?
    var onCurrentSubtitleFontSize: (() -> Int)?
    var onBuildAudioTrackMenuEntries: (() -> [PlayerViewModel.TrackMenuEntry])?
    var onSelectAudioTrack: ((Int32) -> Void)?
    var onBuildEmbeddedSubtitleMenuEntries: (() -> [PlayerViewModel.TrackMenuEntry])?
    var onSelectEmbeddedSubtitle: ((Int32) -> Void)?
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onSpeedKeyDown: ((Double) -> Void)?
    var onSpeedKeyUp: (() -> Void)?
    private var pendingSingleClick: DispatchWorkItem?
    private var speedRepeatTimer: Timer?
    private var activeSpeedDelta: Double = 0
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setupKeyMonitors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pendingSingleClick?.cancel()
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.onSingleClick?()
        }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    deinit {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupKeyMonitors() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            if event.keyCode == 41 { // Semicolon ;
                if !event.isARepeat {
                    self.startSpeedRepeat(delta: -0.25)
                }
                return nil // 消费事件
            }
            if event.keyCode == 39 { // Quote '
                if !event.isARepeat {
                    self.startSpeedRepeat(delta: 0.25)
                }
                return nil // 消费事件
            }
            if self.onKeyEvent?(event) == true {
                return nil
            }
            return event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            if event.keyCode == 41 || event.keyCode == 39 {
                self.stopSpeedRepeat()
            }
            return event
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    private func startSpeedRepeat(delta: Double) {
        guard speedRepeatTimer == nil else { return }
        activeSpeedDelta = delta
        // 立即执行一次
        onSpeedKeyDown?(delta)
        // 启动重复定时器 (0.5秒 = 每秒2次)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.onSpeedKeyDown?(self?.activeSpeedDelta ?? 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        speedRepeatTimer = timer
    }

    private func stopSpeedRepeat() {
        speedRepeatTimer?.invalidate()
        speedRepeatTimer = nil
        onSpeedKeyUp?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "菜单")

        // 1. 音频轨道
        let audioMenuItem = NSMenuItem(title: "音频轨道", action: nil, keyEquivalent: "")
        let audioMenu = NSMenu(title: "音频轨道")
        let audioEntries = onBuildAudioTrackMenuEntries?() ?? []
        if audioEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "无可用音轨", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            audioMenu.addItem(emptyItem)
        } else {
            for entry in audioEntries {
                let item = NSMenuItem(title: entry.name, action: #selector(handleAudioTrackSelection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.state = entry.isSelected ? .on : .off
                audioMenu.addItem(item)
            }
        }
        audioMenuItem.submenu = audioMenu
        menu.addItem(audioMenuItem)

        // 2. 字幕
        let subtitleMenuItem = NSMenuItem(title: "字幕", action: nil, keyEquivalent: "")
        let subtitleMenu = NSMenu(title: "字幕")

        // 2.1 内置字幕
        let embeddedSubtitleMenuItem = NSMenuItem(title: "内置字幕", action: nil, keyEquivalent: "")
        let embeddedSubtitleMenu = NSMenu(title: "内置字幕")
        let embeddedEntries = onBuildEmbeddedSubtitleMenuEntries?() ?? []
        if embeddedEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "无内置字幕", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            embeddedSubtitleMenu.addItem(emptyItem)
        } else {
            for entry in embeddedEntries {
                let item = NSMenuItem(title: entry.name, action: #selector(handleEmbeddedSubtitleSelection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                item.state = entry.isSelected ? .on : .off
                embeddedSubtitleMenu.addItem(item)
            }
        }
        embeddedSubtitleMenuItem.submenu = embeddedSubtitleMenu
        subtitleMenu.addItem(embeddedSubtitleMenuItem)

        // 2.2 外挂字幕
        let externalSubtitleMenuItem = NSMenuItem(title: "外挂字幕", action: nil, keyEquivalent: "")
        let externalSubtitleMenu = NSMenu(title: "外挂字幕")
        let externalEntries = onBuildSubtitleMenuEntries?() ?? []
        if externalEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "无匹配外挂字幕", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            externalSubtitleMenu.addItem(emptyItem)
        } else {
            for entry in externalEntries {
                let item = NSMenuItem(title: entry.title, action: #selector(handleSubtitleSelection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.path ?? NSNull()
                item.state = entry.isSelected ? .on : .off
                externalSubtitleMenu.addItem(item)
            }
        }
        externalSubtitleMenuItem.submenu = externalSubtitleMenu
        subtitleMenu.addItem(externalSubtitleMenuItem)

        subtitleMenu.addItem(NSMenuItem.separator())

        // 2.3 字幕背景透明度
        let opacityMenuItem = NSMenuItem(title: "字幕背景透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: "字幕背景透明度")
        let opacityLevels = [0, 25, 50, 75, 100]
        let currentOpacity = onCurrentSubtitleBackgroundOpacity?() ?? 0
        for level in opacityLevels {
            let item = NSMenuItem(title: "\(level)%", action: #selector(handleSubtitleBackgroundOpacitySelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = level
            item.state = level == currentOpacity ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityMenuItem.submenu = opacityMenu
        subtitleMenu.addItem(opacityMenuItem)

        // 2.4 字幕字体大小
        let fontSizeMenuItem = NSMenuItem(title: "字幕字体大小", action: nil, keyEquivalent: "")
        let fontSizeMenu = NSMenu(title: "字幕字体大小")
        let fontSizes = [28, 36, 44, 55, 66, 80, 100]
        let currentFontSize = onCurrentSubtitleFontSize?() ?? 55
        for size in fontSizes {
            let item = NSMenuItem(title: "\(size)", action: #selector(handleSubtitleFontSizeSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = size == currentFontSize ? .on : .off
            fontSizeMenu.addItem(item)
        }
        fontSizeMenuItem.submenu = fontSizeMenu
        subtitleMenu.addItem(fontSizeMenuItem)

        subtitleMenuItem.submenu = subtitleMenu
        menu.addItem(subtitleMenuItem)

        // 3. 文件信息
        let fileInfoItem = NSMenuItem(title: "文件信息", action: #selector(handleFileInfo), keyEquivalent: "")
        fileInfoItem.target = self
        menu.addItem(fileInfoItem)

        return menu
    }

    @objc
    private func handleFileInfo() {
        onRequestFileInfo?()
    }

    @objc
    private func handleAudioTrackSelection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int32 else { return }
        onSelectAudioTrack?(value)
    }

    @objc
    private func handleEmbeddedSubtitleSelection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int32 else { return }
        onSelectEmbeddedSubtitle?(value)
    }

    @objc
    private func handleSubtitleSelection(_ sender: NSMenuItem) {
        if sender.representedObject is NSNull {
            onSelectSubtitleByPath?(nil)
            return
        }
        onSelectSubtitleByPath?(sender.representedObject as? String)
    }

    @objc
    private func handleSubtitleBackgroundOpacitySelection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        onSetSubtitleBackgroundOpacity?(value)
    }

    @objc
    private func handleSubtitleFontSizeSelection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int else { return }
        onSetSubtitleFontSize?(value)
    }
}
