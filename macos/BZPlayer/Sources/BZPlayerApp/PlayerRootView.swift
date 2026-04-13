import SwiftUI
import AppKit

struct PlayerRootView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var seekValue: Double = 0
    @State private var eventMonitor: Any?
    @State private var shouldShowPlaylist = false
    @State private var isHoveringPlaylist = false
    @State private var isHoveringControlBar = false
    @State private var isControlsVisible = false
    @State private var hideControlsTask: DispatchWorkItem?

    private var shouldPinControlsVisible: Bool {
        !viewModel.hasOpenedFile || viewModel.hasReachedEndOfPlayback
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            playerArea
            controlBar
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .opacity(isControlsVisible ? 1 : 0)
                .offset(y: isControlsVisible ? 0 : 18)
                .allowsHitTesting(isControlsVisible)
                .zIndex(2)
        }
        .animation(.easeOut(duration: 0.12), value: isControlsVisible)
        .onAppear {
            syncControlsVisibilityWithPlaybackState()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKey(event)
            }
        }
        .onDisappear {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
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
        .onReceive(viewModel.$isPaused) { _ in
            syncControlsVisibilityWithPlaybackState()
        }
        .onReceive(viewModel.$currentTime) { _ in
            syncControlsVisibilityWithPlaybackState()
        }
        .onReceive(viewModel.$duration) { _ in
            syncControlsVisibilityWithPlaybackState()
        }
    }

    private var playerArea: some View {
        GeometryReader { proxy in
            ZStack(alignment: .trailing) {
                PlayerContainerView(viewModel: viewModel)
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let triggerWidth = max(proxy.size.width * 0.05, 24)
                            let triggerHeight = max(proxy.size.height * 0.15, 24)
                            shouldShowPlaylist = isHoveringPlaylist || location.x >= proxy.size.width - triggerWidth
                            if shouldPinControlsVisible {
                                revealControlsAndScheduleHide()
                            } else if isHoveringControlBar || location.y >= proxy.size.height - triggerHeight {
                                revealControlsAndScheduleHide()
                            } else if !isHoveringControlBar {
                                hideControlsTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isControlsVisible = false
                                }
                            }
                        case .ended:
                            if !isHoveringPlaylist {
                                shouldShowPlaylist = false
                            }
                            if shouldPinControlsVisible {
                                revealControlsAndScheduleHide()
                            } else if !isHoveringControlBar {
                                hideControlsTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isControlsVisible = false
                                }
                            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onHover { hovering in
            isHoveringPlaylist = hovering
            if hovering {
                shouldShowPlaylist = true
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
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
            }

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
                Text(viewModel.playbackEngineStatus)
                    .foregroundStyle(.secondary)
                Text("双击或按f全屏，点击画面暂停/播放")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .onHover { hovering in
            isHoveringControlBar = hovering
            if hovering {
                revealControlsAndScheduleHide()
            } else {
                scheduleControlsHide()
            }
        }
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
        if !isControlsVisible {
            isControlsVisible = true
        }
        if shouldPinControlsVisible {
            hideControlsTask?.cancel()
            return
        }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        if shouldPinControlsVisible {
            hideControlsTask?.cancel()
            if !isControlsVisible {
                isControlsVisible = true
            }
            return
        }
        hideControlsTask?.cancel()
        let task = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) {
                isControlsVisible = false
                if !isHoveringPlaylist {
                    shouldShowPlaylist = false
                }
            }
        }
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func syncControlsVisibilityWithPlaybackState() {
        if shouldPinControlsVisible {
            hideControlsTask?.cancel()
            if !isControlsVisible {
                isControlsVisible = true
            }
        }
    }
}
