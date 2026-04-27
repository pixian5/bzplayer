import SwiftUI
import AppKit

struct LongPressSpeedButton: NSViewRepresentable {
    let label: String
    let delta: Double
    let onAdjust: (Double) -> Void

    func makeNSView(context: Context) -> LongPressButton {
        let button = LongPressButton(title: label, delta: delta, onAdjust: onAdjust)
        return button
    }

    func updateNSView(_ nsView: LongPressButton, context: Context) {
        nsView.updateLabel(label)
        nsView.updateDelta(delta)
        nsView.updateCallback(onAdjust)
    }
}

final class LongPressButton: NSButton {
    private var delta: Double = 0.25
    private var onAdjust: ((Double) -> Void)?
    private var timer: Timer?

    init(title: String, delta: Double, onAdjust: @escaping (Double) -> Void) {
        self.delta = delta
        self.onAdjust = onAdjust
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.isBordered = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateLabel(_ label: String) {
        self.title = label
    }

    func updateDelta(_ delta: Double) {
        self.delta = delta
    }

    func updateCallback(_ callback: @escaping (Double) -> Void) {
        self.onAdjust = callback
    }

    override func mouseDown(with event: NSEvent) {
        // 立即执行一次
        onAdjust?(delta)

        // 启动重复定时器 (~12次/秒)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.onAdjust?(self?.delta ?? 0)
        }
    }

    override func mouseUp(with event: NSEvent) {
        timer?.invalidate()
        timer = nil
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖拽时继续保持
    }
}
