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
        view.clickView.onKeyEvent = { [weak view] event in
            viewModel.handleKeyEvent(event, in: view?.window)
        }
        view.clickView.onSubtitleMenuRequest = { [weak viewModel] in
            viewModel?.buildSubtitleMenuItems() ?? []
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
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onSubtitleMenuRequest: (() -> [NSMenuItem])?
    private var pendingSingleClick: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
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

    override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "菜单")

        // Subtitle menu items
        if let subtitleItems = onSubtitleMenuRequest?(), !subtitleItems.isEmpty {
            let subtitleMenuItem = NSMenuItem(title: "字幕", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: "字幕")
            for item in subtitleItems {
                submenu.addItem(item)
            }
            subtitleMenuItem.submenu = submenu
            menu.addItem(subtitleMenuItem)
            menu.addItem(NSMenuItem.separator())
        }

        let fileInfoItem = NSMenuItem(title: "文件信息", action: #selector(handleFileInfo), keyEquivalent: "")
        fileInfoItem.target = self
        menu.addItem(fileInfoItem)
        return menu
    }

    @objc
    private func handleFileInfo() {
        onRequestFileInfo?()
    }
}
