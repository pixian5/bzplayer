import AVKit
import SwiftUI

struct PlayerContainerView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel

    func makeNSView(context: Context) -> ClickablePlayerView {
        let view = ClickablePlayerView()
        view.player = viewModel.player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.onSingleClick = {
            viewModel.togglePause()
        }
        view.onDoubleClick = {
            viewModel.toggleFullscreen()
        }
        view.onRequestFileInfo = {
            viewModel.showFileInfo()
        }
        return view
    }

    func updateNSView(_ nsView: ClickablePlayerView, context: Context) {
        nsView.player = viewModel.player
    }
}

final class ClickablePlayerView: AVPlayerView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRequestFileInfo: (() -> Void)?
    private var pendingSingleClick: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
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
