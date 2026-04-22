import SwiftUI
import AppKit
import IOKit.pwr_mgt

struct PlayerRootView: View {
    @EnvironmentObject private var viewModel: PlayerViewModel
    @State private var seekValue: Double = 0
    @State private var shouldShowPlaylist = false
    @State private var isHoveringPlaylist = false
    @State private var isHoveringControlBar = false
    @State private var isControlsVisible = false
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var controlBarHeight: CGFloat = 0
    @State private var mouseIdleTimer: DispatchWorkItem?
    @State private var isCursorHidden = false
    @State private var sleepAssertionID: IOPMAssertionID = 0
    @State private var hasSleepAssertion = false

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
                .allowsHitTesting(isControlsVisible)
                .zIndex(2)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ControlBarHeightKey.self, value: geo.size.height + 12)
                    }
                )

            // Toast 提示
            if viewModel.showToast {
                Text(viewModel.toastMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(8)
                    .transition(.opacity)
                    .zIndex(20)
                    .padding(.bottom, 100)
            }

            // Playback error overlay
            if let error = viewModel.playbackError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.yellow)

                    Text("播放失败")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    Button("确定") {
                        viewModel.playbackError = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .focusable(false)
                }
                .padding(24)
                .background(Color.black.opacity(0.85))
                .cornerRadius(12)
                .frame(maxWidth: 400)
                .zIndex(10)
            }

            // 文件信息面板
            if viewModel.showFileInfoPanel {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.showFileInfoPanel = false
                    }
                    .zIndex(14)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("文件信息")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            viewModel.showFileInfoPanel = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        Text(viewModel.fileInfoContent)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
                .frame(width: 800, height: 600)
                .background(Color.black.opacity(0.92))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                .zIndex(15)
                .onExitCommand {
                    viewModel.showFileInfoPanel = false
                }
            }
        }
        .onPreferenceChange(ControlBarHeightKey.self) { controlBarHeight = $0 }
        .animation(.easeInOut(duration: 0.25), value: isControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showToast)
        .onAppear {
            syncControlsVisibilityWithPlaybackState()
        }
        .onReceive(viewModel.$currentTime) { current in
            guard viewModel.duration > 0 else {
                seekValue = 0
                return
            }
            seekValue = current / viewModel.duration
        }
        .onReceive(viewModel.$windowTitle) { title in
            viewModel.currentWindow?.title = title
        }
        .onReceive(viewModel.$isPaused) { paused in
            syncControlsVisibilityWithPlaybackState()
            if paused {
                releaseSleepAssertion()
            } else {
                acquireSleepAssertion()
            }
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
                            restoreCursorIfNeeded()
                            let triggerWidth = max(proxy.size.width * 0.05, 24)
                            shouldShowPlaylist = isHoveringPlaylist || location.x >= proxy.size.width - triggerWidth
                            let triggerHeight = max(controlBarHeight, 24)
                            let isInControlBarRegion = location.y >= proxy.size.height - triggerHeight
                            if isInControlBarRegion {
                                cancelHide()
                                setControlsVisible(true)
                            } else if !isHoveringPlaylist {
                                // Mouse moved in player area - show controls only if playlist is NOT open
                                setControlsVisible(true)
                            }
                            resetMouseIdleTimer()
                        case .ended:
                            cancelMouseIdleTimer()
                            restoreCursorIfNeeded()
                            if !isHoveringPlaylist {
                                shouldShowPlaylist = false
                            }
                            if !isHoveringControlBar {
                                scheduleHide()
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
            HStack(spacing: 6) {
                Text("播放列表")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    viewModel.togglePlaylistOrder()
                } label: {
                    Text(viewModel.playlistOrder.buttonTitle)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .focusable(false)

                Button {
                    viewModel.cycleLoopMode()
                } label: {
                    Text(viewModel.loopMode.buttonTitle)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .focusable(false)
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.playlist.enumerated()), id: \.offset) { index, url in
                        HStack {
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            if index == viewModel.currentIndex {
                                Image(systemName: "play.fill")
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == viewModel.currentIndex ? Color.blue.opacity(0.35) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectPlaylistItem(index)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.85))
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
                ZStack(alignment: .leading) {
                    // Thicker background track for better visibility
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)
                        .padding(.horizontal, 2)

                    Slider(value: Binding(
                        get: { seekValue },
                        set: { newValue in
                            revealControlsAndScheduleHide()
                            seekValue = newValue
                            viewModel.seek(to: newValue)
                        }
                    ), in: 0...1)
                    .tint(.blue)
                    .accentColor(.blue)
                    .frame(minWidth: 280)
                }

                Text("\(format(viewModel.currentTime)) / \(format(viewModel.duration))")
                    .font(.system(.body, design: .monospaced))
            }

            HStack(spacing: 8) {
                Button("打开文件") {
                    revealControlsAndScheduleHide()
                    viewModel.openFile()
                }
                .keyboardShortcut("o", modifiers: [.command])

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

                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName: viewModel.isMuted || viewModel.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Slider(value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ), in: 0...100)
                .frame(width: 80)
                .foregroundStyle(.white)

                Text(String(format: "%.0f%%", viewModel.volume))
                    .foregroundStyle(.white)
                    .frame(width: 35, alignment: .trailing)

                Divider()
                    .frame(height: 20)
                    .background(Color.white.opacity(0.3))

                Spacer()
                Button {
                    viewModel.switchPlaybackBackend()
                } label: {
                    Text(viewModel.playbackEngineStatus)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
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
        .focusable(false)
        .onHover { hovering in
            isHoveringControlBar = hovering
            if hovering {
                cancelHide()
                setControlsVisible(true)
            } else {
                scheduleHide()
            }
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
        setControlsVisible(true)
    }

    private func syncControlsVisibilityWithPlaybackState() {
        if shouldPinControlsVisible {
            cancelHide()
            setControlsVisible(true)
        }
    }

    private func setControlsVisible(_ visible: Bool) {
        guard isControlsVisible != visible else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isControlsVisible = visible
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [self] in
            if !isHoveringControlBar {
                setControlsVisible(false)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    // MARK: - 鼠标 2s 空闲隐藏

    private func resetMouseIdleTimer() {
        mouseIdleTimer?.cancel()
        let work = DispatchWorkItem { [self] in
            if !isHoveringControlBar && !isHoveringPlaylist && !shouldPinControlsVisible {
                setControlsVisible(false)
                NSCursor.setHiddenUntilMouseMoves(true)
                isCursorHidden = true
            }
        }
        mouseIdleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func cancelMouseIdleTimer() {
        mouseIdleTimer?.cancel()
        mouseIdleTimer = nil
    }

    private func restoreCursorIfNeeded() {
        if isCursorHidden {
            NSCursor.setHiddenUntilMouseMoves(false)
            isCursorHidden = false
        }
    }

    // MARK: - 播放期间阻止息屏

    private func acquireSleepAssertion() {
        guard !hasSleepAssertion else { return }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BZPlayer is playing video" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
            hasSleepAssertion = true
        }
    }

    private func releaseSleepAssertion() {
        guard hasSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        hasSleepAssertion = false
        sleepAssertionID = 0
    }
}

private struct ControlBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 80
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
