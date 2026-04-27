import SwiftUI
import AppKit

struct WindowAccessor: NSViewRepresentable {
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

final class WindowAccessorView: NSView {
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
