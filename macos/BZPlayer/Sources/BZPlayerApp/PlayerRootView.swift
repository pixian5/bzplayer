import SwiftUI
import AppKit

struct PlayerRootView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var seekValue: Double = 0
    @State private var eventMonitor: Any?
    @State private var mouseMoveMonitor: Any?
    @State private var mouseDownMonitor: Any?
    @State private var shouldShowPlaylist = false
    @State private var isControlsVisible = true
    @State private var hideControlsTask: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 0) {
            if isControlsVisible {
                topBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            playerArea
            if isControlsVisible {
                controlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isControlsVisible)
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event)
            }
            mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
                revealControlsAndScheduleHide()
                return event
            }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                revealControlsAndScheduleHide()
                return event
            }
            revealControlsAndScheduleHide()
        }
        .onDisappear {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            if let mouseMoveMonitor {
                NSEvent.removeMonitor(mouseMoveMonitor)
            }
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
            hideControlsTask?.cancel()
        }
        .onReceive(viewModel.$currentTime) { current in
            guard viewModel.duration > 0 else {
                seekValue = 0
                return
            }
            seekValue = current / viewModel.duration
        }
        .onReceive(viewModel.$windowTitle) { title in
            NSApp.keyWindow?.title = title
        }
    }

    private var playerArea: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                PlayerContainerView(viewModel: viewModel)
                    .background(Color.black)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            revealControlsAndScheduleHide()
                            shouldShowPlaylist = location.x >= proxy.size.width - 36
                        case .ended:
                            shouldShowPlaylist = false
                        }
                    }

                if shouldShowPlaylist && !viewModel.playlist.isEmpty {
                    playlistPanel
                        .padding(.trailing, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: shouldShowPlaylist)
        }
    }

    private var playlistPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("播放列表")
                .font(.headline)
                .foregroundStyle(.white)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.playlist.enumerated()), id: \.offset) { index, url in
                        Button {
                            viewModel.selectPlaylistItem(index)
                        } label: {
                            HStack {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                                if index == viewModel.currentIndex {
                                    Image(systemName: "play.fill")
                                }
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == viewModel.currentIndex ? Color.blue.opacity(0.35) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.72))
        .cornerRadius(10)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button("打开文件") {
                revealControlsAndScheduleHide()
                viewModel.openFile()
            }

            Slider(value: Binding(
                get: { seekValue },
                set: { newValue in
                    revealControlsAndScheduleHide()
                    seekValue = newValue
                    viewModel.seek(to: newValue)
                }
            ), in: 0...1)
            .frame(minWidth: 280)

            Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                .font(.system(.body, design: .monospaced))

            Spacer()
            Text("双击或按f全屏，点击画面暂停/播放")
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
                    revealControlsAndScheduleHide()
                    viewModel.setSpeed(speed)
                }
                .buttonStyle(.bordered)
                .tint(abs(viewModel.speed - speed) < 0.001 ? .blue : .gray)
            }

            Button("-0.25x") {
                revealControlsAndScheduleHide()
                viewModel.adjustSpeed(by: -0.25)
            }
            Button("+0.25x") {
                revealControlsAndScheduleHide()
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
        revealControlsAndScheduleHide()
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

    private func revealControlsAndScheduleHide() {
        isControlsVisible = true
        hideControlsTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.2)) {
                isControlsVisible = false
                shouldShowPlaylist = false
            }
        }
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }
}
