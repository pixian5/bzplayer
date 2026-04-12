import SwiftUI
import AppKit

struct PlayerRootView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var seekValue: Double = 0
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            PlayerContainerView(viewModel: viewModel)
                .background(Color.black)
            controlBar
        }
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event)
            }
        }
        .onDisappear {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }
        .onReceive(viewModel.$currentTime) { current in
            guard viewModel.duration > 0 else {
                seekValue = 0
                return
            }
            seekValue = current / viewModel.duration
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("打开文件") {
                viewModel.openFile()
            }

            Button(viewModel.isPaused ? "播放" : "暂停") {
                viewModel.togglePause()
            }

            Slider(value: Binding(
                get: { seekValue },
                set: { newValue in
                    seekValue = newValue
                    viewModel.seek(to: newValue)
                }
            ), in: 0...1)
            .frame(minWidth: 280)

            Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                .font(.system(.body, design: .monospaced))

            Spacer()
            Text("双击或按 f 全屏，点击画面暂停/播放")
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var controlBar: some View {
        HStack(spacing: 8) {
            Text("速度：")
            ForEach(viewModel.speedCandidates, id: \.self) { speed in
                Button("\(speed, specifier: "%g")x") {
                    viewModel.setSpeed(speed)
                }
                .buttonStyle(.bordered)
                .tint(abs(viewModel.speed - speed) < 0.001 ? .blue : .gray)
            }

            Button("-0.25x") {
                viewModel.adjustSpeed(by: -0.25)
            }
            Button("+0.25x") {
                viewModel.adjustSpeed(by: 0.25)
            }

            Text(String(format: "当前：%.2fx", viewModel.speed))
            Text(viewModel.syncText)
                .foregroundStyle(viewModel.syncText.contains("稳定") ? .green : .orange)
            Spacer()
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else {
            return event
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            viewModel.toggleFullscreen()
            return nil
        case " ":
            viewModel.togglePause()
            return nil
        default:
            return event
        }
    }

    private func format(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "00:00" }
        let total = Int(time)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
