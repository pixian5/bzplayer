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
    @State private var hoveredPlaylistIndex: Int?

    private var shouldPinControlsVisible: Bool {
        !viewModel.hasOpenedFile || viewModel.hasReachedEndOfPlayback
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            playerArea
            ControlBarView(
                seekValue: $seekValue,
                isHoveringControlBar: $isHoveringControlBar,
                revealControlsAndScheduleHide: revealControlsAndScheduleHide,
                setControlsVisible: setControlsVisible,
                cancelHide: cancelHide,
                scheduleHide: scheduleHide
            )
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
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
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
        .onReceive(viewModel.$openedFilePath) { _ in
            if !shouldPinControlsVisible {
                resetMouseIdleTimer()
            }
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

                if !viewModel.hasOpenedFile && viewModel.showRecentFiles && !viewModel.recentFiles.isEmpty {
                    RecentFilesView(containerWidth: proxy.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if shouldShowPlaylist && !viewModel.playlist.isEmpty {
                    PlaylistPanelView(
                        shouldShowPlaylist: $shouldShowPlaylist,
                        isHoveringPlaylist: $isHoveringPlaylist,
                        hoveredPlaylistIndex: $hoveredPlaylistIndex
                    )
                        .padding(.trailing, 8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: shouldShowPlaylist)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - 鼠标 1s 空闲隐藏

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
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
