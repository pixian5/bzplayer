import AppKit
import Foundation
@preconcurrency import VLCKitSPM
import CoreText

@MainActor
final class VLCPlayer: NSObject {
    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onEndReached: (() -> Void)?

    private let library: VLCLibrary
    private var mediaPlayer: VLCMediaPlayer
    private var currentMedia: VLCMedia?
    private var timeObserverToken: NSObjectProtocol?
    private var stateObserverToken: NSObjectProtocol?
    private var pendingResumeAt: Double?
    private var didFireFileLoaded = false
    private var wasPlayingBeforeSeek: Bool?
    private var pendingPlayTask: Task<Void, Never>?
    private var pendingLoadTask: Task<Void, Never>?
    private var mediaGeneration = UUID()
    private var isTransitioning = false
    private var shouldPlay = false
    private var currentURL: URL?
    private var needsStopWait = false
    private var configuredAudioDelayMs: Double = 0
    private var configuredSubtitleFontSize = 55
    private var configuredSubtitleBackgroundOpacity = 0
    /// Desired playback rate. VLCPlayer recreates VLCMediaPlayer for every load to isolate
    /// VLCKit 4 stop/load transitions, so this value must outlive the concrete player instance.
    private var configuredRate: Float = 1.0
    private weak var currentAttachedView: VLCVideoView?

    override init() {
        library = VLCLibrary(options: [
            "--freetype-font=/System/Library/Fonts/STHeiti Light.ttc",
            "--subsdec-encoding=GB18030",
            // VLCKit 4 已移除 --avcodec-hw；硬件解码由模块、视频编码和 macOS 能力共同协商，
            // 因此不能沿用 3.x 的启动参数强制它。
            // macOS 26 上 OpenGL vout（macosx / caopengllayer）会在渲染线程的
            // vout_display_opengl_Prepare 命中断言并 abort（SIGABRT），播放约 15s 后崩溃。
            // 模块短名是 samplebufferdisplay（AVSampleBufferDisplayLayer / CoreMedia），
            // 不是 avsamplebuffer——后者是音频输出模块；写成 vout 会导致有声无画。
            // macosx 是旧 NSOpenGL vout，同样不能用来修这个崩溃。
            "--vout=samplebufferdisplay"
        ])
        mediaPlayer = VLCMediaPlayer(library: library)
        super.init()
        mediaPlayer.delegate = self
        // VLCKit 4 defaults time updates to 1s; 0.5s balances responsiveness and energy.
        mediaPlayer.timeChangeUpdateInterval = 0.5
        bindNotifications()
        registerCustomFonts()
    }

    deinit {
        pendingPlayTask?.cancel()
        pendingLoadTask?.cancel()
        if let t = timeObserverToken { NotificationCenter.default.removeObserver(t) }
        if let t = stateObserverToken { NotificationCenter.default.removeObserver(t) }
    }

    func attach(to view: VLCVideoView) {
        guard currentAttachedView !== view else { return }
        // Clear old drawable before attaching new one to avoid OpenGL assert
        mediaPlayer.drawable = nil
        currentAttachedView = view
        mediaPlayer.drawable = view
    }

    func detach() {
        mediaPlayer.drawable = nil
        currentAttachedView = nil
    }

    func load(
        url: URL,
        resumeAt: Double?,
        audioDelayMs: Double = 0,
        subtitleFontSize: Int = 55,
        subtitleBackgroundOpacity: Int = 0,
        noVideo: Bool = false
    ) {
        cancelPendingPlay()
        pendingLoadTask?.cancel()
        pendingLoadTask = nil

        let generation = UUID()
        mediaGeneration = generation
        pendingResumeAt = resumeAt
        didFireFileLoaded = false
        currentURL = url
        configuredAudioDelayMs = audioDelayMs
        configuredSubtitleFontSize = max(1, subtitleFontSize)
        configuredSubtitleBackgroundOpacity = min(max(subtitleBackgroundOpacity, 0), 100)
        isTransitioning = true
        shouldPlay = false

        pendingLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let oldPlayer = self.mediaPlayer
            let hadMedia = self.currentMedia != nil || oldPlayer.media != nil || self.needsStopWait
            if hadMedia {
                self.removeNotifications()
                oldPlayer.stop()
                let didStop = await self.waitForStopped(oldPlayer)
                guard !Task.isCancelled, self.mediaGeneration == generation else { return }
                guard didStop else {
                    self.pendingLoadTask = nil
                    self.onStatusChanged?("VLC 停止旧媒体超时，请重试")
                    return
                }
                oldPlayer.media = nil
                self.currentMedia = nil
                self.needsStopWait = false
            }

            guard !Task.isCancelled, self.mediaGeneration == generation else { return }
            let player = self.makeMediaPlayer()
            self.mediaPlayer = player
            self.bindNotifications(for: player, generation: generation)
            guard let media = VLCMedia(url: url) else {
                self.pendingLoadTask = nil
                self.isTransitioning = false
                self.onStatusChanged?("VLC 无法打开媒体")
                return
            }
            media.addOption(":subsdec-encoding=GB18030")
            media.addOption(":freetype-font=/System/Library/Fonts/STHeiti Light.ttc")
            media.addOption(":freetype-rel-fontsize=\(self.configuredSubtitleFontSize)")
            media.addOption(":freetype-background-opacity=\(self.configuredSubtitleBackgroundOpacity * 255 / 100)")
            // 不能强制 :codec=videotoolbox：许多 Mac 的 VideoToolbox 会拒绝 av01，强制
            // 解码器列表还会阻断 VLC 回退到 dav1d/libavcodec。保留自动协商可让 H.264/HEVC
            // 优先使用可用硬件路径，并让 AV1 使用 VLC 4 实际支持的解码路径。
            if noVideo {
                media.addOption(":no-video")
            }
            self.currentMedia = media
            player.media = media
            self.isTransitioning = false
            self.pendingLoadTask = nil
            self.applyConfiguredAudioDelay()
            self.applyConfiguredRate(to: player)
            if self.shouldPlay {
                player.play()
                // VLCKit 4 often only honors rate after play has started.
                self.applyConfiguredRate(to: player)
            }
        }
    }

    func play() {
        shouldPlay = true
        cancelPendingPlay()
        guard !isTransitioning, pendingLoadTask == nil else { return }
        mediaPlayer.play()
        applyConfiguredRate(to: mediaPlayer)
    }

    func pause() {
        shouldPlay = false
        cancelPendingPlay()
        guard !isTransitioning else { return }
        mediaPlayer.pause()
    }

    func stop() {
        mediaGeneration = UUID()
        isTransitioning = false
        shouldPlay = false
        cancelPendingPlay()
        pendingLoadTask?.cancel()
        pendingLoadTask = nil
        removeNotifications()
        mediaPlayer.drawable = nil
        mediaPlayer.stop()
        needsStopWait = true
        currentMedia = nil
        currentURL = nil
        pendingResumeAt = nil
    }

    func seek(seconds: Double) {
        guard seconds >= 0 else { return }
        let ms = milliseconds(for: seconds)

        cancelPendingPlay(resetSeekState: false)

        if wasPlayingBeforeSeek == nil {
            wasPlayingBeforeSeek = mediaPlayer.isPlaying
        }

        if wasPlayingBeforeSeek == true {
            mediaPlayer.pause()
            mediaPlayer.time = VLCTime(int: ms)
            pendingPlayTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 150_000_000) // 150ms delay
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.mediaPlayer.play()
                    self.applyConfiguredRate(to: self.mediaPlayer)
                    self.wasPlayingBeforeSeek = nil
                    self.pendingPlayTask = nil
                } catch {
                    // Task cancelled
                }
            }
        } else {
            mediaPlayer.time = VLCTime(int: ms)
            wasPlayingBeforeSeek = nil
        }
    }

    func setSpeed(_ speed: Double) {
        guard speed.isFinite else { return }
        // Clamp to a practical range; libvlc rejects non-positive rates.
        let rate = Float(min(max(speed, 0.01), 32))
        configuredRate = rate
        applyConfiguredRate(to: mediaPlayer)
    }

    private func applyConfiguredRate(to player: VLCMediaPlayer) {
        player.rate = configuredRate
    }

    func setVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        let normalized = min(max(volume, 0), 100)
        mediaPlayer.audio?.volume = Int32(clamping: Int(normalized.rounded()))
    }

    func setMuted(_ muted: Bool) {
        mediaPlayer.audio?.isMuted = muted
    }

    func setAudioDelay(_ delayMs: Double) {
        guard delayMs.isFinite else { return }
        configuredAudioDelayMs = delayMs
        applyConfiguredAudioDelay()
    }

    private func applyConfiguredAudioDelay() {
        guard currentMedia != nil, !isTransitioning else { return }
        let microseconds = (configuredAudioDelayMs * 1_000).rounded()
        if microseconds >= Double(Int.max) {
            mediaPlayer.currentAudioPlaybackDelay = Int.max
        } else if microseconds <= Double(Int.min) {
            mediaPlayer.currentAudioPlaybackDelay = Int.min
        } else {
            mediaPlayer.currentAudioPlaybackDelay = Int(microseconds)
        }
    }

    private func waitForStopped(_ player: VLCMediaPlayer) async -> Bool {
        for _ in 0..<200 {
            guard !Task.isCancelled else { return false }
            // VLCKit 4 不再提供 .ended；自然播完与主动 stop 都会进入 .stopped，因此调用方
            // 必须依赖媒体代次和 shouldPlay 区分“播放结束”与“正在切换媒体”。
            switch player.state {
            case .stopped, .error:
                return true
            default:
                break
            }
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    private func makeMediaPlayer() -> VLCMediaPlayer {
        let player = VLCMediaPlayer(library: library)
        player.delegate = self
        player.timeChangeUpdateInterval = 0.5
        applyConfiguredRate(to: player)
        // Attach drawable after other setup to avoid transient states
        if let view = currentAttachedView {
            player.drawable = view
        }
        return player
    }

    func reloadCurrentMedia(
        resumeAt: Double?,
        startPaused: Bool,
        audioDelayMs: Double,
        subtitleFontSize: Int,
        subtitleBackgroundOpacity: Int,
        noVideo: Bool = false
    ) {
        guard let currentURL else { return }
        load(
            url: currentURL,
            resumeAt: resumeAt,
            audioDelayMs: audioDelayMs,
            subtitleFontSize: subtitleFontSize,
            subtitleBackgroundOpacity: subtitleBackgroundOpacity,
            noVideo: noVideo
        )
        if startPaused {
            pause()
        } else {
            play()
        }
    }

    func setHardwareDecodingEnabled(_ enabled: Bool) {
        // VLC manages hardware decoding internally
    }

    func setExternalSubtitle(url: URL) {
        mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }

    func disableSubtitle() {
        mediaPlayer.deselectAllTextTracks()
    }

    /// Track list index is exposed as Int32 for menu/ViewModel compatibility.
    /// VLCKit 4 uses string track IDs internally; selection is by list index.
    var subtitleTracks: [(Int32, String)] {
        mediaPlayer.textTracks.enumerated().map { index, track in
            (Int32(index), track.trackName)
        }
    }

    var currentSubtitleIndex: Int32 {
        get {
            if let index = mediaPlayer.textTracks.firstIndex(where: { $0.isSelected }) {
                return Int32(index)
            }
            return -1
        }
        set {
            if newValue < 0 {
                mediaPlayer.deselectAllTextTracks()
                return
            }
            let tracks = mediaPlayer.textTracks
            guard tracks.indices.contains(Int(newValue)) else { return }
            mediaPlayer.selectTrack(at: Int(newValue), type: .text)
        }
    }

    var audioTracks: [(Int32, String)] {
        mediaPlayer.audioTracks.enumerated().map { index, track in
            (Int32(index), track.trackName)
        }
    }

    var currentAudioIndex: Int32 {
        get {
            if let index = mediaPlayer.audioTracks.firstIndex(where: { $0.isSelected }) {
                return Int32(index)
            }
            return -1
        }
        set {
            if newValue < 0 {
                mediaPlayer.deselectAllAudioTracks()
                return
            }
            let tracks = mediaPlayer.audioTracks
            guard tracks.indices.contains(Int(newValue)) else { return }
            mediaPlayer.selectTrack(at: Int(newValue), type: .audio)
        }
    }

    func cancelPendingRender() {
        // VLC handles rendering natively, no pending renders to cancel
    }

    private func registerCustomFonts() {
        let fontURL = Bundle.module.url(forResource: "simhei", withExtension: "ttf") ??
                      Bundle.module.url(forResource: "simhei", withExtension: "ttf", subdirectory: "Resources") ??
                      Bundle.main.url(forResource: "simhei", withExtension: "ttf")

        guard let url = fontURL else {
            BZLogger.error("Bundled simhei.ttf not found in module or main bundle")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            BZLogger.info("Registered bundled simhei.ttf: \(url.path)")
        } else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            BZLogger.error("Failed to register bundled simhei.ttf: \(errorDesc)")
        }
    }

    func requestRender() {
        // VLC handles rendering natively
    }

    func renderCurrentFrame() {
        // VLC handles rendering natively
    }

    func getDoubleProperty(_ name: String) -> Double? {
        switch name {
        case "time-pos":
            let ms = mediaPlayer.time.value?.doubleValue ?? 0
            return ms / 1000.0
        case "duration":
            let ms = currentMedia?.length.value?.doubleValue ?? 0
            return ms / 1000.0
        default:
            return nil
        }
    }

    private func bindNotifications() {
        bindNotifications(for: mediaPlayer, generation: mediaGeneration)
    }

    private func bindNotifications(for player: VLCMediaPlayer, generation: UUID) {
        removeNotifications()
        let center = NotificationCenter.default
        timeObserverToken = center.addObserver(
            forName: VLCMediaPlayer.timeChangedNotification,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.mediaPlayer === player else { return }
                self.handleTimeChanged(for: generation, player: player)
            }
        }
        stateObserverToken = center.addObserver(
            forName: VLCMediaPlayer.stateChangedNotification,
            object: player,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.mediaPlayer === player else { return }
                self.handleStateChanged(for: generation, player: player)
            }
        }
    }

    private func removeNotifications() {
        if let timeObserverToken {
            NotificationCenter.default.removeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let stateObserverToken {
            NotificationCenter.default.removeObserver(stateObserverToken)
            self.stateObserverToken = nil
        }
    }

    private func handleTimeChanged(for generation: UUID, player: VLCMediaPlayer) {
        guard generation == mediaGeneration, !isTransitioning, currentMedia != nil else { return }
        let ms = player.time.value?.doubleValue ?? 0
        let seconds = ms / 1000.0
        onTimeChanged?(seconds)

        // Emit duration once it becomes available
        if let media = currentMedia {
            let durationMs = media.length.value?.doubleValue ?? 0
            if durationMs > 0 {
                onDurationChanged?(durationMs / 1000.0)
            }
        }

        fireFileLoadedIfReady(player: player)

        // Seek to resume position after first time tick
        if let resumeAt = pendingResumeAt, resumeAt > 0, seconds >= 0 {
            pendingResumeAt = nil
            let ms = milliseconds(for: resumeAt)
            player.time = VLCTime(int: ms)
        }
    }

    private func milliseconds(for seconds: Double) -> Int32 {
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite else {
            return seconds.sign == .minus ? Int32.min : Int32.max
        }
        if milliseconds >= Double(Int32.max) { return Int32.max }
        if milliseconds <= Double(Int32.min) { return Int32.min }
        return Int32(milliseconds.rounded())
    }

    private func cancelPendingPlay(resetSeekState: Bool = true) {
        pendingPlayTask?.cancel()
        pendingPlayTask = nil
        if resetSeekState {
            wasPlayingBeforeSeek = nil
        }
    }

    private func fireFileLoadedIfReady(player: VLCMediaPlayer) {
        guard !didFireFileLoaded, currentMedia != nil else { return }
        let durationMs = currentMedia?.length.value?.doubleValue ?? 0
        guard durationMs > 0 || player.state == .playing else { return }
        didFireFileLoaded = true
        onFileLoaded?()
    }

    private func handleStateChanged(for generation: UUID, player: VLCMediaPlayer) {
        guard generation == mediaGeneration, !isTransitioning, currentMedia != nil else { return }
        switch player.state {
        case .playing:
            // VLCKit 4 可能在媒体真正开始时覆盖预设速率；在 .playing 再写一次，保证切换
            // 媒体、恢复播放与手动改速三条路径的最终速率一致。
            applyConfiguredRate(to: player)
            fireFileLoadedIfReady(player: player)
            onPauseChanged?(false)
        case .paused:
            fireFileLoadedIfReady(player: player)
            onPauseChanged?(true)
        case .stopped:
            // VLCKit 4 不再提供 .ended，自然播完会落在 .stopped。主动 stop()/load() 会先
            // 解绑通知、清空 currentMedia 并令 shouldPlay 为 false；只有仍期待播放时才向
            // 上层发送 onEndReached，避免切换内核或重载字幕时被误判为文件结束。
            if shouldPlay {
                shouldPlay = false
                onEndReached?()
            }
        case .error:
            if shouldPlay {
                shouldPlay = false
                onEndReached?()
            }
        default:
            break
        }
    }
}

extension VLCPlayer: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        // Handled via NotificationCenter observer on main queue
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Handled via NotificationCenter observer on main queue
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor [weak self] in
            guard let self, length > 0 else { return }
            self.onDurationChanged?(Double(length) / 1000.0)
            self.fireFileLoadedIfReady(player: self.mediaPlayer)
        }
    }
}
