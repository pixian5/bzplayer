import AppKit
import AVKit
import OpenGL.GL3
import SwiftUI

struct PlayerContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.onViewReady = { playerSurfaceView in
            viewModel.attachPlayerView(playerSurfaceView)
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
        view.clickView.onKeyEvent = { [weak view] event in
            viewModel.handleKeyEvent(event, in: view?.window)
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
        nsView.updateBackend(viewModel.playbackBackend, player: viewModel.nativePlayer)
        // Only attach the view for mpv backend to avoid unnecessary rendering calls to a hidden view
        if nsView.window != nil && viewModel.playbackBackend == .mpv {
            viewModel.attachPlayerView(nsView.playerSurfaceView)
        }
    }
}

final class PlayerHostView: NSView {
    let nativePlayerView = AVPlayerView()
    let playerSurfaceView = MpvRenderView(frame: .zero)
    let clickView = ClickCaptureView()
    var onViewReady: ((MpvRenderView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        nativePlayerView.translatesAutoresizingMaskIntoConstraints = false
        nativePlayerView.controlsStyle = .none
        nativePlayerView.videoGravity = .resizeAspect
        nativePlayerView.showsFullScreenToggleButton = false
        nativePlayerView.player = nil

        playerSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        clickView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nativePlayerView)
        addSubview(playerSurfaceView)
        addSubview(clickView)

        NSLayoutConstraint.activate([
            nativePlayerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativePlayerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativePlayerView.topAnchor.constraint(equalTo: topAnchor),
            nativePlayerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            playerSurfaceView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerSurfaceView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerSurfaceView.topAnchor.constraint(equalTo: topAnchor),
            playerSurfaceView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onViewReady?(playerSurfaceView)
    }

    func updateBackend(_ backend: PlayerViewModel.PlaybackBackend, player: AVPlayer) {
        switch backend {
        case .native:
            if nativePlayerView.player !== player {
                nativePlayerView.player = player
            }
            nativePlayerView.isHidden = false
            playerSurfaceView.isHidden = true
        case .mpv:
            nativePlayerView.player = nil
            nativePlayerView.isHidden = true
            playerSurfaceView.isHidden = false
        }
    }
}

final class MpvRenderView: NSOpenGLView {
    private var isReady = false
    var onRendererReady: ((MpvRenderView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect, pixelFormat: Self.makePixelFormat())!
        wantsBestResolutionOpenGLSurface = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        false
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)
        glDisable(GLenum(GL_DITHER))
        isReady = true
        onRendererReady?(self)
    }

    override func reshape() {
        super.reshape()
        openGLContext?.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if openGLContext != nil, isReady {
            onRendererReady?(self)
        }
    }

    func renderFrame(_ renderer: (_ size: SIMD2<Int32>, _ fbo: Int32, _ flipY: Int32) -> Void) {
        // Critical safeguard: stop rendering if view is hidden, detached from window, or context is invalid
        guard isReady, !isHidden, window != nil, let ctx = openGLContext else { return }
        
        ctx.makeCurrentContext()
        
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(Int(bounds.width * scale), 1)
        let height = max(Int(bounds.height * scale), 1)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        renderer(SIMD2(Int32(width), Int32(height)), 0, 1)
        glFlush()
        ctx.flushBuffer()
    }

    private static func makePixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            0
        ]
        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attributes) else {
            fatalError("Unable to create NSOpenGLPixelFormat")
        }
        return pixelFormat
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

        let subtitleMenuItem = NSMenuItem(title: "字幕", action: nil, keyEquivalent: "")
        let subtitleMenu = NSMenu(title: "字幕")
        let subtitleEntries = onBuildSubtitleMenuEntries?() ?? []
        if subtitleEntries.isEmpty {
            let emptyItem = NSMenuItem(title: "无匹配字幕", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            subtitleMenu.addItem(emptyItem)
        } else {
            for entry in subtitleEntries {
                let item = NSMenuItem(title: entry.title, action: #selector(handleSubtitleSelection(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.path ?? NSNull()
                item.state = entry.isSelected ? .on : .off
                subtitleMenu.addItem(item)
            }
        }

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
        subtitleMenu.addItem(NSMenuItem.separator())
        subtitleMenu.addItem(opacityMenuItem)
        subtitleMenuItem.submenu = subtitleMenu
        menu.addItem(subtitleMenuItem)

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
}
