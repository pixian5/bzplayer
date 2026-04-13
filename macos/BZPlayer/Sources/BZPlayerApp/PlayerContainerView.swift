import AppKit
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
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.window != nil {
            viewModel.attachPlayerView(nsView.playerSurfaceView)
        }
    }
}

final class PlayerHostView: NSView {
    let playerSurfaceView = MpvRenderView()
    let clickView = ClickCaptureView()
    var onViewReady: ((MpvRenderView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        playerSurfaceView.translatesAutoresizingMaskIntoConstraints = false
        clickView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerSurfaceView)
        addSubview(clickView)

        NSLayoutConstraint.activate([
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
}

final class MpvRenderView: NSView {
    private var frameBuffer = Data()
    private var frameWidth = 0
    private var frameHeight = 0
    private var stride = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        false
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func renderFrame(_ renderer: (_ size: SIMD2<Int32>, _ stride: Int, _ pointer: UnsafeMutableRawPointer) -> Void) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(Int(bounds.width * scale), 1)
        let height = max(Int(bounds.height * scale), 1)
        let newStride = ((width * 4) + 63) & ~63
        let requiredBytes = newStride * height

        if frameBuffer.count != requiredBytes {
            frameBuffer = Data(count: requiredBytes)
        }
        frameWidth = width
        frameHeight = height
        stride = newStride

        frameBuffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            renderer(SIMD2(Int32(width), Int32(height)), newStride, baseAddress)
        }

        layer?.contents = makeRenderedImage()
    }

    private func makeRenderedImage() -> CGImage? {
        let provider = frameBuffer.withUnsafeBytes { rawBuffer -> CGDataProvider? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return CGDataProvider(dataInfo: nil, data: baseAddress, size: frameBuffer.count) { _, _, _ in }
        }

        guard let provider else { return nil }
        return CGImage(
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

final class ClickCaptureView: NSView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRequestFileInfo: (() -> Void)?
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

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "菜单")
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
