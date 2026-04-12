import AppKit
import SwiftUI

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
        viewModel.attachPlayerView(view.playerSurfaceView)
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        viewModel.attachPlayerView(nsView.playerSurfaceView)
    }
}

final class PlayerHostView: NSView {
    let playerSurfaceView = NSView()
    let clickView = ClickCaptureView()

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
