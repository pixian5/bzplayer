import AppKit
import AVFoundation
import AVKit
import SwiftUI
import VLCKitSPM

struct PlayerContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    // Explicit inputs so SwiftUI always calls updateNSView when subtitle text changes.
    // Relying only on @ObservedObject can miss high-frequency text updates on some macOS versions.
    private var backend: PlayerViewModel.PlaybackBackend { viewModel.playbackBackend }
    private var nativePlayer: AVPlayer { viewModel.nativePlayer }
    private var nativeRefreshID: Int { viewModel.nativePlayerSurfaceRefreshID }
    private var videoVisible: Bool { !viewModel.isAudioOnlyMode }
    private var subtitleText: String {
        viewModel.playbackBackend == .native ? viewModel.nativeSubtitleText : ""
    }
    private var subtitleFontSize: CGFloat { viewModel.nativeSubtitlePointSize }
    private var subtitleBackgroundOpacity: Int { viewModel.subtitleBackgroundOpacity }
    private var subtitleRenderID: Int { viewModel.nativeSubtitleRenderID }

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.clickView.translate = { [weak viewModel] key in
            viewModel?.t(key) ?? key
        }
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
        view.clickView.onCopyFile = { [weak viewModel] in
            guard let viewModel = viewModel, let url = viewModel.currentFileURL else { return }
            viewModel.copyFileToClipboard(url: url)
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
            backend,
            player: nativePlayer,
            nativeRefreshID: nativeRefreshID,
            videoVisible: videoVisible
        )
        // AppKit subtitle label above AVPlayerLayer (not SwiftUI overlay).
        // Touch subtitleRenderID so SwiftUI tracks it as an update dependency.
        _ = subtitleRenderID
        nsView.updateNativeSubtitle(
            text: subtitleText,
            fontSize: subtitleFontSize,
            backgroundOpacity: subtitleBackgroundOpacity
        )
        if nsView.window != nil, backend == .vlc {
            viewModel.attachVLCView(nsView.vlcVideoView)
        }
    }
}

/// Hosts native AVPlayer via AVPlayerLayer (not AVPlayerView) so external
/// subtitle labels can reliably sit above the video without being covered by
/// AVPlayerView's private video layer hierarchy.
final class PlayerHostView: NSView {
    private let nativeVideoContainer = NSView()
    private let playerLayer = AVPlayerLayer()
    let vlcVideoView = VLCVideoView(frame: .zero)
    let clickView = ClickCaptureView()
    private let subtitleContainer = NSView()
    private let subtitleBackground = NSView()
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private var lastNativeRefreshID = 0
    private var lastSubtitleText = ""
    private var lastSubtitleFontSize: CGFloat = -1
    private var lastSubtitleOpacity = -1
    private weak var boundPlayer: AVPlayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        nativeVideoContainer.translatesAutoresizingMaskIntoConstraints = false
        nativeVideoContainer.wantsLayer = true
        nativeVideoContainer.layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        // Ensure video is always below subtitles / click capture.
        playerLayer.zPosition = 0
        nativeVideoContainer.layer?.addSublayer(playerLayer)

        vlcVideoView.translatesAutoresizingMaskIntoConstraints = false
        vlcVideoView.isHidden = true
        clickView.translatesAutoresizingMaskIntoConstraints = false

        subtitleContainer.translatesAutoresizingMaskIntoConstraints = false
        subtitleContainer.wantsLayer = true
        subtitleContainer.isHidden = true
        subtitleContainer.layer?.zPosition = 100

        subtitleBackground.translatesAutoresizingMaskIntoConstraints = false
        subtitleBackground.wantsLayer = true
        subtitleBackground.layer?.cornerRadius = 8
        subtitleBackground.layer?.backgroundColor = NSColor.clear.cgColor

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isEditable = false
        subtitleLabel.isSelectable = false
        subtitleLabel.isBezeled = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.backgroundColor = .clear
        subtitleLabel.textColor = .white
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        subtitleLabel.shadow = shadow

        // Bottom → top: video, VLC, click capture, subtitle overlay.
        addSubview(nativeVideoContainer)
        addSubview(vlcVideoView)
        addSubview(clickView)
        addSubview(subtitleContainer)
        subtitleContainer.addSubview(subtitleBackground)
        subtitleBackground.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            nativeVideoContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeVideoContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeVideoContainer.topAnchor.constraint(equalTo: topAnchor),
            nativeVideoContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            vlcVideoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vlcVideoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            vlcVideoView.topAnchor.constraint(equalTo: topAnchor),
            vlcVideoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            clickView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickView.topAnchor.constraint(equalTo: topAnchor),
            clickView.bottomAnchor.constraint(equalTo: bottomAnchor),

            subtitleContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            subtitleContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),
            subtitleContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -64),

            subtitleBackground.leadingAnchor.constraint(greaterThanOrEqualTo: subtitleContainer.leadingAnchor),
            subtitleBackground.trailingAnchor.constraint(lessThanOrEqualTo: subtitleContainer.trailingAnchor),
            subtitleBackground.centerXAnchor.constraint(equalTo: subtitleContainer.centerXAnchor),
            subtitleBackground.topAnchor.constraint(equalTo: subtitleContainer.topAnchor),
            subtitleBackground.bottomAnchor.constraint(equalTo: subtitleContainer.bottomAnchor),
            subtitleBackground.widthAnchor.constraint(lessThanOrEqualTo: subtitleContainer.widthAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: subtitleBackground.leadingAnchor, constant: 18),
            subtitleLabel.trailingAnchor.constraint(equalTo: subtitleBackground.trailingAnchor, constant: -18),
            subtitleLabel.topAnchor.constraint(equalTo: subtitleBackground.topAnchor, constant: 10),
            subtitleLabel.bottomAnchor.constraint(equalTo: subtitleBackground.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // Keep AVPlayerLayer bounds in sync with its host view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = nativeVideoContainer.bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never let the subtitle layer steal clicks from ClickCaptureView.
        let hit = super.hitTest(point)
        if hit === subtitleContainer || hit === subtitleBackground || hit === subtitleLabel {
            return clickView
        }
        return hit
    }

    func updateBackend(
        _ backend: PlayerViewModel.PlaybackBackend,
        player: AVPlayer,
        nativeRefreshID: Int,
        videoVisible: Bool
    ) {
        switch backend {
        case .native:
            let needsRebind = boundPlayer !== player || playerLayer.player !== player
            let needsRefresh = nativeRefreshID != lastNativeRefreshID
            if needsRebind || needsRefresh {
                // Drop then reattach so the surface re-primes after decoder warmup / player replacement.
                playerLayer.player = nil
                playerLayer.player = player
                boundPlayer = player
            }
            lastNativeRefreshID = nativeRefreshID
            nativeVideoContainer.isHidden = !videoVisible
            playerLayer.isHidden = !videoVisible
            vlcVideoView.isHidden = true
            playerLayer.frame = nativeVideoContainer.bounds
        case .vlc:
            playerLayer.player = nil
            boundPlayer = nil
            nativeVideoContainer.isHidden = true
            playerLayer.isHidden = true
            vlcVideoView.isHidden = !videoVisible
            // VLC draws its own subtitles.
            updateNativeSubtitle(
                text: "",
                fontSize: lastSubtitleFontSize > 0 ? lastSubtitleFontSize : 30,
                backgroundOpacity: lastSubtitleOpacity >= 0 ? lastSubtitleOpacity : 0
            )
        }
    }

    func updateNativeSubtitle(text: String, fontSize: CGFloat, backgroundOpacity: Int) {
        let normalizedOpacity = max(0, min(100, backgroundOpacity))
        let normalizedFont = max(16, min(72, fontSize))

        if text != lastSubtitleText {
            lastSubtitleText = text
            subtitleLabel.stringValue = text
        }

        if normalizedFont != lastSubtitleFontSize {
            lastSubtitleFontSize = normalizedFont
            subtitleLabel.font = .systemFont(ofSize: normalizedFont, weight: .semibold)
        }

        if normalizedOpacity != lastSubtitleOpacity {
            lastSubtitleOpacity = normalizedOpacity
            // Always keep a faint backdrop when opacity is 0 so thin white text
            // remains readable; user opacity scales on top of a minimal shadow box.
            let alpha = max(CGFloat(normalizedOpacity) / 100.0, text.isEmpty ? 0 : 0.25)
            subtitleBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(alpha).cgColor
        } else if !text.isEmpty, lastSubtitleOpacity == 0 {
            // Re-apply minimal backdrop after text reappears.
            subtitleBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        }

        subtitleContainer.isHidden = text.isEmpty
        if !text.isEmpty {
            // Keep the overlay above everything else in this host.
            subtitleContainer.layer?.zPosition = 200
            clickView.layer?.zPosition = 50
            nativeVideoContainer.layer?.zPosition = 0
        }
    }
}

final class ClickCaptureView: NSView {
    var translate: ((String) -> String)?
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
    var onCopyFile: (() -> Void)?
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
        pendingSingleClick?.cancel()
        speedRepeatTimer?.invalidate()
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
            if let firstResponder = self.window?.firstResponder,
               firstResponder is NSText || firstResponder is NSTextView {
                return event
            }
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

    private func t(_ key: String) -> String {
        return translate?(key) ?? key
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: t("菜单"))

        // 1. 音频轨道
        let audioMenuItem = NSMenuItem(title: t("音频轨道"), action: nil, keyEquivalent: "")
        let audioMenu = NSMenu(title: t("音频轨道"))
        let audioEntries = onBuildAudioTrackMenuEntries?() ?? []
        if audioEntries.isEmpty {
            let emptyItem = NSMenuItem(title: t("无可用音轨"), action: nil, keyEquivalent: "")
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
        let subtitleMenuItem = NSMenuItem(title: t("字幕"), action: nil, keyEquivalent: "")
        let subtitleMenu = NSMenu(title: t("字幕"))

        // 2.1 内置字幕
        let embeddedSubtitleMenuItem = NSMenuItem(title: t("内置字幕"), action: nil, keyEquivalent: "")
        let embeddedSubtitleMenu = NSMenu(title: t("内置字幕"))
        let embeddedEntries = onBuildEmbeddedSubtitleMenuEntries?() ?? []
        if embeddedEntries.isEmpty {
            let emptyItem = NSMenuItem(title: t("无内置字幕"), action: nil, keyEquivalent: "")
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
        let externalSubtitleMenuItem = NSMenuItem(title: t("外挂字幕"), action: nil, keyEquivalent: "")
        let externalSubtitleMenu = NSMenu(title: t("外挂字幕"))
        let externalEntries = onBuildSubtitleMenuEntries?() ?? []
        if externalEntries.isEmpty {
            let emptyItem = NSMenuItem(title: t("无匹配外挂字幕"), action: nil, keyEquivalent: "")
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
        let opacityMenuItem = NSMenuItem(title: t("字幕背景透明度"), action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu(title: t("字幕背景透明度"))
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
        let fontSizeMenuItem = NSMenuItem(title: t("字幕字体大小"), action: nil, keyEquivalent: "")
        let fontSizeMenu = NSMenu(title: t("字幕字体大小"))
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
        let fileInfoItem = NSMenuItem(title: t("文件信息"), action: #selector(handleFileInfo), keyEquivalent: "")
        fileInfoItem.target = self
        menu.addItem(fileInfoItem)

        // 4. 复制
        let copyItem = NSMenuItem(title: t("复制"), action: #selector(handleCopyFile), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

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

    @objc
    private func handleCopyFile() {
        onCopyFile?()
    }
}
