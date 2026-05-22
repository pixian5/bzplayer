import AVFoundation
import AVKit
import CMpv
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers
import VLCKitSPM

// Debug logger
private let debugLogURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BZPlayer.log")
private func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogURL.path) {
            if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: debugLogURL)
        }
    }
}

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    struct SubtitleMenuEntry {
        let title: String
        let path: String?
        let isSelected: Bool
    }

    enum PlaybackBackend: String {
        case native
        case mpv
        case vlc
    }

    enum PlaylistOrder: String, CaseIterable {
        case ascending
        case descending

        var buttonTitle: String {
            switch self {
            case .ascending:
                "正序"
            case .descending:
                "倒序"
            }
        }
    }

    enum LoopMode: String, CaseIterable {
        case singleFile
        case playlist
        case none

        var buttonTitle: String {
            switch self {
            case .singleFile:
                "单文件"
            case .playlist:
                "列表循环"
            case .none:
                "不循环"
            }
        }
    }

    enum WindowOpenBehavior: String, CaseIterable {
        case fullscreen
        case maximized
        case videoSize
        case rememberLast
        case fitLargest

        var title: String {
            switch self {
            case .fullscreen:
                "全屏"
            case .maximized:
                "最大化"
            case .videoSize:
                "视频大小"
            case .rememberLast:
                "记忆上次"
            case .fitLargest:
                "尽量大"
            }
        }
    }

    @Published var isPaused = true
    @Published var speed: Double = 1.0
    @Published var memorySpeed: Double = 1.0
    @Published var volume: Double = 100.0
    @Published var isMuted = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var openedFilePath: String = ""
    @Published var syncText = "播放链路：系统原生"
    @Published var isSeeking: Bool = false
    @Published var playlist: [URL] = []
    @Published var currentIndex: Int = -1
    @Published var windowTitle = PlayerViewModel.defaultWindowTitle
    @Published var fileAssociationStatus = "未执行格式关联"
    @Published var playbackEngineStatus = "AVPlayer"
    @Published var playbackBackend: PlaybackBackend = .native
    @Published var shortcutSeekSeconds: Double
    @Published var shortcutFrameStepCount: Int
    @Published var previousFileKeyCode: UInt16
    @Published var nextFileKeyCode: UInt16
    @Published var audioStepDownKeyCode: UInt16
    @Published var audioStepUpKeyCode: UInt16
    @Published var speedToggleKeyCode: UInt16
    @Published var playlistOrder: PlaylistOrder
    @Published var loopMode: LoopMode
    @Published var windowOpenBehavior: WindowOpenBehavior
    @Published var allowMultipleWindows: Bool
    @Published var playbackError: String?
    @Published var audioDelayMs: Double
    @Published var audioDelayStepMs: Double
    @Published var toastMessage: String = ""
    @Published var showToast: Bool = false
    @Published var showRecentFiles: Bool = true
    @Published var recentFiles: [String] = []
    @Published var subtitleBackgroundOpacity: Int
    @Published var playlistDurations: [URL: Double] = [:]
    @Published var nativePlayerSurfaceRefreshID: Int = 0

    var onShowFileInfo: ((String) -> Void)?

    let mpvPlayer = MpvPlayer()
    let vlcPlayer = VLCPlayer()
    let nativePlayer = AVPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8, 16]

    var hasOpenedFile: Bool {
        currentFileURL != nil
    }

    var currentMediaURL: URL? {
        currentFileURL
    }

    var currentWindow: NSWindow? {
        attachedWindow
    }

    var hasReachedEndOfPlayback: Bool {
        duration > 0 && isPaused && currentTime >= max(duration - 0.5, 0)
    }

    private var currentFileURL: URL?
    private var currentVideoSize: CGSize?
    private var currentNominalFPS: Double = 30
    private var nativeTimeObserver: Any?
    private var nativeItemStatusObserver: NSKeyValueObservation?
    private var nativeEndObserver: NSObjectProtocol?
    private weak var attachedWindow: NSWindow?
    private static var globalLastNavigationTime: TimeInterval = 0
    private static var hasCompletedNativeVP9Warmup = false
    private var lastAutoNextJumpTimes: [TimeInterval] = []
    private var windowFrameObservers: [NSObjectProtocol] = []
    private var hasAppliedInitialWindowBehavior = false
    private var nativeStallCount = 0
    private var lastStallPosition: Double = 0
    private var attemptedBackendSwitch = false
    private var mpvAttemptedSoftwareFallback = false
    private var playbackFailureTimer: Timer?
    private var selectedSubtitlePath: String?

    private static let shortcutSeekSecondsKey = "shortcutSeekSeconds"
    private static let shortcutFrameStepCountKey = "shortcutFrameStepCount"
    private static let previousFileKeyCodeKey = "previousFileKeyCode"
    private static let nextFileKeyCodeKey = "nextFileKeyCode"
    private static let audioStepDownKeyCodeKey = "audioStepDownKeyCode"
    private static let audioStepUpKeyCodeKey = "audioStepUpKeyCode"
    private static let speedToggleKeyCodeKey = "speedToggleKeyCode"
    private static let playlistOrderKey = "playlistOrder"
    private static let loopModeKey = "loopMode"
    private static let windowOpenBehaviorKey = "windowOpenBehavior"
    private static let volumeKey = "volume"
    private static let isMutedKey = "isMuted"
    private static let allowMultipleWindowsKey = "allowMultipleWindows"
    private static let audioDelayMsKey = "audioDelayMs"
    private static let audioDelayStepMsKey = "audioDelayStepMs"
    private static let showRecentFilesKey = "showRecentFiles"
    private static let subtitleBackgroundOpacityKey = "subtitleBackgroundOpacity"

    // MARK: - 文件存储路径
    private static var settingsDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BZPlayer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var settingsURL: URL {
        settingsDir.appendingPathComponent("settings.json")
    }

    private static var fileSettingsURL: URL {
        settingsDir.appendingPathComponent("fileSettings.json")
    }

    // MARK: - 全局设置数据结构
    private struct AppSettings: Codable {
        var shortcutSeekSeconds: Double = 5
        var shortcutFrameStepCount: Int = 1
        var previousFileKeyCode: Int = 33
        var nextFileKeyCode: Int = 30
        var audioStepDownKeyCode: Int = 43
        var audioStepUpKeyCode: Int = 47
        var speedToggleKeyCode: Int = 24
        var playlistOrder: String = PlaylistOrder.ascending.rawValue
        var loopMode: String = LoopMode.playlist.rawValue
        var windowOpenBehavior: String = WindowOpenBehavior.maximized.rawValue
        var volume: Double = 100.0
        var isMuted: Bool = false
        var allowMultipleWindows: Bool = true
        var audioDelayMs: Double = 0
        var audioDelayStepMs: Double = 50
        var showRecentFiles: Bool = true
        var subtitleBackgroundOpacity: Int = 0
        var lastWindowFrame: String? = nil
        var lastUsedSpeed: Double = 1.0
    }

    // MARK: - 单文件设置数据结构（进度/速度/音频延迟）
    private struct FileSettings: Codable {
        var progress: Double = 0
        var speed: Double = 1.0
        var audioDelayMs: Double = 0
    }

    override init() {
        let settings = Self.loadSettings()
        shortcutSeekSeconds = max(settings.shortcutSeekSeconds, 0.1)
        shortcutFrameStepCount = max(settings.shortcutFrameStepCount, 1)
        previousFileKeyCode = UInt16(settings.previousFileKeyCode)
        nextFileKeyCode = UInt16(settings.nextFileKeyCode)
        audioStepDownKeyCode = UInt16(settings.audioStepDownKeyCode)
        audioStepUpKeyCode = UInt16(settings.audioStepUpKeyCode)
        speedToggleKeyCode = UInt16(settings.speedToggleKeyCode)
        playlistOrder = PlaylistOrder(rawValue: settings.playlistOrder) ?? .ascending
        loopMode = LoopMode(rawValue: settings.loopMode) ?? .playlist
        windowOpenBehavior = WindowOpenBehavior(rawValue: settings.windowOpenBehavior) ?? .maximized
        volume = settings.volume
        isMuted = settings.isMuted
        allowMultipleWindows = settings.allowMultipleWindows
        audioDelayMs = settings.audioDelayMs
        audioDelayStepMs = settings.audioDelayStepMs
        showRecentFiles = settings.showRecentFiles
        subtitleBackgroundOpacity = Self.clampSubtitleOpacity(settings.subtitleBackgroundOpacity)
        recentFiles = Self.loadRecentFilesFromDisk() ?? []
        super.init()

        mpvPlayer.setVolume(volume)
        mpvPlayer.setMuted(isMuted)
        vlcPlayer.setVolume(volume)
        vlcPlayer.setMuted(isMuted)
        nativePlayer.volume = Float(volume / 100.0)
        nativePlayer.isMuted = isMuted

        bindMpvCallbacks()
        bindVLCCallbacks()
        bindNativePlayer()
        selectBackend(.native)
        mpvPlayer.setSubtitleBackgroundOpacity(subtitleBackgroundOpacity)
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    private func saveSettings() {
        var settings = Self.loadSettings()
        settings.shortcutSeekSeconds = shortcutSeekSeconds
        settings.shortcutFrameStepCount = shortcutFrameStepCount
        settings.previousFileKeyCode = Int(previousFileKeyCode)
        settings.nextFileKeyCode = Int(nextFileKeyCode)
        settings.audioStepDownKeyCode = Int(audioStepDownKeyCode)
        settings.audioStepUpKeyCode = Int(audioStepUpKeyCode)
        settings.speedToggleKeyCode = Int(speedToggleKeyCode)
        settings.playlistOrder = playlistOrder.rawValue
        settings.loopMode = loopMode.rawValue
        settings.windowOpenBehavior = windowOpenBehavior.rawValue
        settings.volume = volume
        settings.isMuted = isMuted
        settings.allowMultipleWindows = allowMultipleWindows
        settings.audioDelayMs = audioDelayMs
        settings.audioDelayStepMs = audioDelayStepMs
        settings.showRecentFiles = showRecentFiles
        settings.subtitleBackgroundOpacity = subtitleBackgroundOpacity
        settings.lastUsedSpeed = speed
        if let frame = attachedWindow {
            settings.lastWindowFrame = NSStringFromRect(frame.frame)
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: Self.settingsURL)
    }

    private static func loadFileSettings() -> [String: FileSettings] {
        guard let data = try? Data(contentsOf: fileSettingsURL),
              let dict = try? JSONDecoder().decode([String: FileSettings].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveFileSettings(_ dict: [String: FileSettings]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: fileSettingsURL)
    }

    private func loadFileSettings(for url: URL) -> FileSettings {
        let dict = Self.loadFileSettings()
        return dict[url.path] ?? FileSettings()
    }

    private func saveFileSettings(for url: URL, _ settings: FileSettings) {
        var dict = Self.loadFileSettings()
        dict[url.path] = settings
        Self.saveFileSettings(dict)
    }

    deinit {
        if let nativeTimeObserver {
            nativePlayer.removeTimeObserver(nativeTimeObserver)
        }
        if let nativeEndObserver {
            NotificationCenter.default.removeObserver(nativeEndObserver)
        }
    }

    func attachPlayerView(_ view: MpvRenderView) {
        mpvPlayer.attach(to: view)
    }

    func attachVLCView(_ view: VLCVideoView) {
        vlcPlayer.attach(to: view)
    }

    func attachWindow(_ window: NSWindow) {
        if attachedWindow !== window {
            attachedWindow = window
            hasAppliedInitialWindowBehavior = false
            installWindowFrameObservers(for: window)
        }
        applyInitialWindowBehaviorIfNeeded()
    }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadPlaylist(with: url)
            openFromPlaylist(url)
        }
    }

    func openExternalFiles(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let normalizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return }
        loadPlaylist(with: normalizedURL)

        // Check if selected URL is a directory (folder) or a file
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            // If folder, open the first file in playlist
            if let firstFile = playlist.first {
                openFromPlaylist(firstFile)
            }
        } else {
            // If file, open the selected file
            openFromPlaylist(normalizedURL)
        }
    }

    func play() {
        // If playback has reached the very end, restart from beginning
        let isAtVeryEnd = duration > 0 && currentTime >= duration - 0.5
        if isAtVeryEnd {
            seek(to: 0)
        }
        switch playbackBackend {
        case .native:
            nativePlayer.play()
            nativePlayer.rate = Float(speed)
            // 强制刷新视频帧：AVPlayer 暂停后恢复时可能不渲染，seek 0.001s 强制刷新
            let currentTime = nativePlayer.currentTime()
            nativePlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
            isPaused = false
        case .mpv:
            mpvPlayer.play()
            isPaused = false
        case .vlc:
            vlcPlayer.play()
            isPaused = false
        }
    }

    func pause() {
        switch playbackBackend {
        case .native:
            nativePlayer.pause()
        case .mpv:
            mpvPlayer.pause()
        case .vlc:
            vlcPlayer.pause()
        }
        isPaused = true
        saveCurrentProgress()
    }

    func prepareForWindowClose() {
        closeCurrentPlaybackFile(showToast: false)
    }

    func closeCurrentFile() {
        closeCurrentPlaybackFile(showToast: true)
    }

    private func closeCurrentPlaybackFile(showToast: Bool) {
        saveCurrentProgress()
        switch playbackBackend {
        case .native:
            nativePlayer.pause()
            nativePlayer.replaceCurrentItem(with: nil)
        case .mpv:
            mpvPlayer.stop()
        case .vlc:
            vlcPlayer.stop()
        }
        currentFileURL = nil
        openedFilePath = ""
        currentTime = 0
        duration = 0
        isPaused = true
        currentIndex = -1
        selectedSubtitlePath = nil
        windowTitle = Self.defaultWindowTitle
        attachedWindow?.title = windowTitle
        playbackError = nil
        attemptedBackendSwitch = false
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil
        if showToast {
            showToastMessage("已关闭当前文件")
        }
    }

    func togglePause() {
        isPaused ? play() : pause()
    }

    func setVolume(_ newVolume: Double) {
        volume = max(0, min(100, newVolume))
        mpvPlayer.setVolume(volume)
        vlcPlayer.setVolume(volume)
        nativePlayer.volume = Float(volume / 100.0)
        print("[BZPlayer] setVolume: \(volume), nativePlayer.volume: \(nativePlayer.volume), isMuted: \(isMuted)")
        if volume > 0 {
            isMuted = false
            mpvPlayer.setMuted(false)
            vlcPlayer.setMuted(false)
            nativePlayer.isMuted = false
        }
        saveSettings()
    }

    func toggleMute() {
        isMuted.toggle()
        mpvPlayer.setMuted(isMuted)
        vlcPlayer.setMuted(isMuted)
        nativePlayer.isMuted = isMuted
        saveSettings()
    }

    func selectPlaylistItem(_ index: Int) {
        guard playlist.indices.contains(index) else { return }
        openFromPlaylist(playlist[index])
    }

    func previousFile() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - Self.globalLastNavigationTime > 1.0 else { return }
        Self.globalLastNavigationTime = now
        print("[BZPlayer] Manually navigating to previous file")
        moveInPlaylist(step: -1)
    }
    
    func nextFile() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - Self.globalLastNavigationTime > 1.0 else { return }
        Self.globalLastNavigationTime = now
        print("[BZPlayer] Manually navigating to next file")
        moveInPlaylist(step: 1)
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let targetTime = duration * progress
        let time = CMTime(seconds: targetTime, preferredTimescale: 600)
        isSeeking = true
        if playbackBackend == .native {
            nativePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isSeeking = false
                }
            }
        } else if playbackBackend == .vlc {
            vlcPlayer.seek(seconds: targetTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSeeking = false
            }
        } else {
            mpvPlayer.seek(seconds: targetTime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSeeking = false
            }
        }
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.25), 16)
        if let url = currentFileURL {
            saveSpeedForFile(url)
            debugLog("[BZPlayer] saveSpeedForFile called - url: \(url.lastPathComponent), speed: \(speed)")
        }
        // Remember as global last used speed and save all settings
        saveSettings()

        switch playbackBackend {
        case .native:
            nativePlayer.rate = isPaused ? 0 : Float(speed)
        case .mpv:
            mpvPlayer.setSpeed(speed)
        case .vlc:
            vlcPlayer.setSpeed(speed)
        }
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
        showToastMessage(String(format: "速度: %.2fx", speed))
    }

    func toggleSpeed() {
        let currentSpeed = speed
        setSpeed(memorySpeed)
        memorySpeed = currentSpeed
        // 显示 Toast 提示
        showToastMessage(String(format: "速度: %.2fx", speed))
    }

    func setShortcutSeekSeconds(_ value: Double) {
        let normalized = max(value, 0.1)
        shortcutSeekSeconds = normalized
        saveSettings()
    }

    func setShortcutFrameStepCount(_ value: Int) {
        let normalized = max(value, 1)
        shortcutFrameStepCount = normalized
        saveSettings()
    }

    func setPreviousFileKeyCode(_ value: UInt16) {
        previousFileKeyCode = value
        saveSettings()
    }

    func setNextFileKeyCode(_ value: UInt16) {
        nextFileKeyCode = value
        saveSettings()
    }

    func setAudioStepDownKeyCode(_ value: UInt16) {
        audioStepDownKeyCode = value
        saveSettings()
    }

    func setAudioStepUpKeyCode(_ value: UInt16) {
        audioStepUpKeyCode = value
        saveSettings()
    }

    func setSpeedToggleKeyCode(_ value: UInt16) {
        speedToggleKeyCode = value
        saveSettings()
    }

    func setWindowOpenBehavior(_ behavior: WindowOpenBehavior) {
        windowOpenBehavior = behavior
        saveSettings()
        applyInitialWindowBehaviorIfNeeded(force: true)
    }

    func setAllowMultipleWindows(_ value: Bool) {
        allowMultipleWindows = value
        saveSettings()
    }

    func setShowRecentFiles(_ value: Bool) {
        showRecentFiles = value
        saveSettings()
    }

    func setSubtitleBackgroundOpacity(_ value: Int) {
        let normalized = Self.clampSubtitleOpacity(value)
        subtitleBackgroundOpacity = normalized
        saveSettings()
        mpvPlayer.setSubtitleBackgroundOpacity(normalized)
    }

    func setAudioDelayStepMs(_ value: Double) {
        let normalized = max(value, 1)
        audioDelayStepMs = normalized
        saveSettings()
    }

    func subtitleMenuEntries() -> [SubtitleMenuEntry] {
        let available = discoverSubtitleFilesForCurrentMedia()
        var entries: [SubtitleMenuEntry] = [
            SubtitleMenuEntry(title: "关闭字幕", path: nil, isSelected: selectedSubtitlePath == nil)
        ]

        entries.append(contentsOf: available.map { url in
            SubtitleMenuEntry(
                title: url.lastPathComponent,
                path: url.path,
                isSelected: selectedSubtitlePath == url.path
            )
        })
        return entries
    }

    func selectSubtitle(path: String?) {
        guard let mediaURL = currentFileURL else { return }

        if path == nil {
            selectedSubtitlePath = nil
            mpvPlayer.disableSubtitle()
            showToastMessage("字幕：已关闭")
            return
        }

        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        selectedSubtitlePath = path

        let resumeAt = currentTime > 0 && currentTime < duration ? currentTime : nil
        let wasPaused = isPaused
        if playbackBackend != .mpv {
            selectBackend(.mpv)
            mpvAttemptedSoftwareFallback = false
            mpvPlayer.setHardwareDecodingEnabled(true)
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: mediaURL, resumeAt: resumeAt)
            if !wasPaused {
                mpvPlayer.play()
                isPaused = false
            } else {
                mpvPlayer.pause()
                isPaused = true
            }
            applyAudioDelay()
        }

        mpvPlayer.setExternalSubtitle(url: URL(fileURLWithPath: path))
        mpvPlayer.setSubtitleBackgroundOpacity(subtitleBackgroundOpacity)
        showToastMessage("字幕：\((path as NSString).lastPathComponent)")
    }

    private func addRecentFile(_ url: URL) {
        let path = url.path
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 10 {
            recentFiles = Array(recentFiles.prefix(10))
        }
        Self.saveRecentFilesToDisk(recentFiles)
    }

    private static var persistentRecentFilesURL: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("BZPlayer")
        if let dir = dir, !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir?.appendingPathComponent("recentFiles.json")
    }

    private static func loadRecentFilesFromDisk() -> [String]? {
        guard let url = persistentRecentFilesURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    private static func saveRecentFilesToDisk(_ files: [String]) {
        guard let url = persistentRecentFilesURL, let data = try? JSONEncoder().encode(files) else { return }
        try? data.write(to: url)
    }

    func adjustAudioDelay(by deltaMs: Double) {
        audioDelayMs += deltaMs
        saveSettings()
        applyAudioDelay()
        if let url = currentFileURL {
            var fileSettings = loadFileSettings(for: url)
            fileSettings.audioDelayMs = audioDelayMs
            saveFileSettings(for: url, fileSettings)
        }
        showToastMessage(String(format: "音频延迟: %.0f ms", audioDelayMs))
    }

    func resetAudioDelay() {
        audioDelayMs = 0
        saveSettings()
        applyAudioDelay()
        if let url = currentFileURL {
            var fileSettings = loadFileSettings(for: url)
            fileSettings.audioDelayMs = 0
            saveFileSettings(for: url, fileSettings)
        }
        showToastMessage("音频延迟: 已重置")
    }

    func applyAudioDelay() {
        guard playbackBackend == .mpv, let handle = mpvPlayer.playerHandle else { return }
        var delay = audioDelayMs / 1000.0
        withUnsafeMutablePointer(to: &delay) {
            _ = mpv_set_property(handle, "audio-delay", MPV_FORMAT_DOUBLE, $0)
        }
    }

    func refreshPreferences() {
        let settings = Self.loadSettings()
        shortcutSeekSeconds = max(settings.shortcutSeekSeconds, 0.1)
        shortcutFrameStepCount = max(settings.shortcutFrameStepCount, 1)
        previousFileKeyCode = UInt16(settings.previousFileKeyCode)
        nextFileKeyCode = UInt16(settings.nextFileKeyCode)
        windowOpenBehavior = WindowOpenBehavior(rawValue: settings.windowOpenBehavior) ?? windowOpenBehavior
        allowMultipleWindows = settings.allowMultipleWindows
        audioDelayStepMs = max(settings.audioDelayStepMs, 1)
        showRecentFiles = settings.showRecentFiles
        subtitleBackgroundOpacity = Self.clampSubtitleOpacity(settings.subtitleBackgroundOpacity)
        mpvPlayer.setSubtitleBackgroundOpacity(subtitleBackgroundOpacity)
    }

    func togglePlaylistOrder() {
        playlist.reverse()
        playlistOrder = playlistOrder == .ascending ? .descending : .ascending
        saveSettings()
        if let currentFileURL {
            currentIndex = playlist.firstIndex(of: currentFileURL) ?? -1
        }
    }

    func cycleLoopMode() {
        switch loopMode {
        case .singleFile:
            loopMode = .playlist
        case .playlist:
            loopMode = .none
        case .none:
            loopMode = .singleFile
        }
        saveSettings()
    }

    func switchPlaybackBackend() {
        guard let url = currentFileURL else { return }
        let resumeAt = currentTime > 0 && currentTime < duration ? currentTime : nil
        let wasPaused = isPaused
        let newBackend: PlaybackBackend
        switch playbackBackend {
        case .native: newBackend = .mpv
        case .mpv:    newBackend = .vlc
        case .vlc:    newBackend = .native
        }
        selectBackend(newBackend)

        switch newBackend {
        case .native:
            openWithNative(url: url, resumeAt: resumeAt, startPaused: wasPaused)
        case .mpv:
            mpvAttemptedSoftwareFallback = false
            mpvPlayer.setHardwareDecodingEnabled(true)
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: url, resumeAt: resumeAt)
            if wasPaused {
                mpvPlayer.pause()
            } else {
                mpvPlayer.play()
            }
            applyAudioDelay()
        case .vlc:
            vlcPlayer.setSpeed(speed)
            vlcPlayer.load(url: url, resumeAt: resumeAt)
            if wasPaused {
                vlcPlayer.pause()
            } else {
                vlcPlayer.play()
            }
        }
    }

    func seekBy(seconds delta: Double) {
        guard hasOpenedFile else { return }
        let baseTime = currentTime.isFinite ? currentTime : 0
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, baseTime + delta))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        if playbackBackend == .native {
            nativePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isSeeking = false
                }
            }
        } else if playbackBackend == .vlc {
            vlcPlayer.seek(seconds: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSeeking = false
            }
        } else {
            mpvPlayer.seek(seconds: target)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSeeking = false
            }
        }
        currentTime = target
    }

    func seekByConfiguredFrameStep(_ direction: Int) {
        guard direction != 0 else { return }
        let fps = max(currentNominalFPS, 1)
        let seconds = Double(shortcutFrameStepCount) / fps * Double(direction)
        seekBy(seconds: seconds)
    }

    func toggleFullscreen(in window: NSWindow? = nil) {
        (window ?? attachedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }




    func showFileInfo() {
        guard let url = currentFileURL else {
            onShowFileInfo?("当前未打开媒体文件。")
            return
        }

        Task {
            let text = await buildFileInfoText(url: url)
            await MainActor.run {
                self.onShowFileInfo?(text)
            }
        }
    }

    func associateCommonVideoFormats() {
        let bundleID = (Bundle.main.bundleIdentifier ?? "tech.sbbz.bzplayer") as CFString
        let commonExtensions = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "ts", "mpeg", "mpg"]
        let bundleURL = Bundle.main.bundleURL as CFURL

        _ = LSRegisterURL(bundleURL, true)

        let typeMappings = commonExtensions.compactMap { ext -> (ext: String, type: UTType)? in
            guard let type = UTType(filenameExtension: ext) else { return nil }
            return (ext, type)
        }

        for (_, type) in typeMappings {
            let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleID)
            if status != noErr {
                fileAssociationStatus = "关联失败：系统拒绝更新 LaunchServices。"
                return
            }
        }

        let initialVerification = verifyAssociations(typeMappings: typeMappings, bundleID: bundleID as String)
        if initialVerification.failed.isEmpty {
            fileAssociationStatus = "已注册并关联：\(initialVerification.associated.joined(separator: ", "))"
            return
        }

        forceRefreshAssociationCache(typeMappings: typeMappings, bundleID: bundleID as String)
        let finalVerification = verifyAssociations(typeMappings: typeMappings, bundleID: bundleID as String)

        if finalVerification.failed.isEmpty {
            fileAssociationStatus = "已强制刷新并关联：\(finalVerification.associated.joined(separator: ", "))"
        } else if finalVerification.associated.isEmpty {
            fileAssociationStatus = "关联失败：\(finalVerification.failed.joined(separator: ", "))；请确认程序位于 /Applications/BZPlayer.app"
        } else {
            fileAssociationStatus = "部分成功，已关联：\(finalVerification.associated.joined(separator: ", "))；失败：\(finalVerification.failed.joined(separator: ", "))；请确认程序位于 /Applications/BZPlayer.app"
        }
    }

    private func verifyAssociations(typeMappings: [(ext: String, type: UTType)], bundleID: String) -> (associated: [String], failed: [String]) {
        var associated: [String] = []
        var failed: [String] = []

        for (ext, type) in typeMappings {
            let viewer = LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, .viewer)?.takeRetainedValue() as String?
            let all = LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, .all)?.takeRetainedValue() as String?
            if viewer == bundleID && all == bundleID {
                associated.append(ext)
            } else {
                failed.append(ext)
            }
        }
        return (associated, failed)
    }

    private func forceRefreshAssociationCache(typeMappings: [(ext: String, type: UTType)], bundleID: String) {
        let typeIDs = typeMappings.map(\.type.identifier)
        let python = """
import os, plistlib, time
path = os.path.expanduser('~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist')
bundle_id = \(bundleID.debugDescription)
targets = set(\(typeIDs.debugDescription))
with open(path, 'rb') as f:
    data = plistlib.load(f)
handlers = data.get('LSHandlers', [])
filtered = [h for h in handlers if h.get('LSHandlerContentType') not in targets]
now = int(time.time())
prefix = []
for content_type in sorted(targets):
    prefix.append({
        'LSHandlerContentType': content_type,
        'LSHandlerRoleAll': bundle_id,
        'LSHandlerRoleViewer': bundle_id,
        'LSHandlerModificationDate': now,
        'LSHandlerPreferredVersions': {'LSHandlerRoleAll': '-', 'LSHandlerRoleViewer': '-'},
    })
data['LSHandlers'] = prefix + filtered
with open(path, 'wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
"""
        let shellScript = """
/usr/bin/python3 - <<'PY'
\(python)
PY
killall cfprefsd >/dev/null 2>&1 || true
killall lsd >/dev/null 2>&1 || true
"""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", shellScript]
        try? process.run()
        process.waitUntilExit()
    }

    private func bindMpvCallbacks() {
        mpvPlayer.onTimeChanged = { [weak self] time in
            guard let self, self.playbackBackend == .mpv else { return }
            self.currentTime = time.isFinite ? time : 0
            if Int(self.currentTime) % 1 == 0 {
                self.saveCurrentProgress()
            }
        }
        mpvPlayer.onDurationChanged = { [weak self] duration in
            guard let self, self.playbackBackend == .mpv else { return }
            self.duration = duration.isFinite ? duration : 0
        }
        mpvPlayer.onPauseChanged = { [weak self] paused in
            guard let self, self.playbackBackend == .mpv else { return }
            self.isPaused = paused
        }
        mpvPlayer.onFileLoaded = { [weak self] in
            guard let self, self.playbackBackend == .mpv else { return }
            self.mpvPlayer.setSubtitleBackgroundOpacity(self.subtitleBackgroundOpacity)
            if let path = self.selectedSubtitlePath {
                self.mpvPlayer.setExternalSubtitle(url: URL(fileURLWithPath: path))
            }
        }
        mpvPlayer.onStatusChanged = { [weak self] status in
            guard let self, self.playbackBackend == .mpv else { return }
            self.playbackEngineStatus = status
        }
        mpvPlayer.onEndReached = { [weak self] in
            guard let self, self.playbackBackend == .mpv else { return }
            self.handlePlaybackFinished()
        }
        mpvPlayer.onHwdecChanged = { [weak self] hwdecMode in
            guard let self, self.playbackBackend == .mpv else { return }
            // hwdec-current returns "no" for software, or the actual hw api name for hardware
            let isHardware = hwdecMode != "no" && !hwdecMode.isEmpty
            let modeLabel = isHardware ? "硬解" : "软解"
            self.syncText = "播放链路：mpv/libmpv · \(modeLabel)"
            self.playbackEngineStatus = "mpv/libmpv · \(modeLabel)"
        }
    }

    private func bindVLCCallbacks() {
        vlcPlayer.onTimeChanged = { [weak self] time in
            guard let self, self.playbackBackend == .vlc else { return }
            self.currentTime = time.isFinite ? time : 0
            if Int(self.currentTime) % 1 == 0 {
                self.saveCurrentProgress()
            }
        }
        vlcPlayer.onDurationChanged = { [weak self] duration in
            guard let self, self.playbackBackend == .vlc else { return }
            self.duration = duration.isFinite ? duration : 0
        }
        vlcPlayer.onPauseChanged = { [weak self] paused in
            guard let self, self.playbackBackend == .vlc else { return }
            self.isPaused = paused
        }
        vlcPlayer.onFileLoaded = { [weak self] in
            guard let self, self.playbackBackend == .vlc else { return }
            self.syncText = "播放链路：VLC/libvlc"
            self.playbackEngineStatus = "VLC/libvlc"
        }
        vlcPlayer.onStatusChanged = { [weak self] status in
            guard let self, self.playbackBackend == .vlc else { return }
            self.playbackEngineStatus = status
        }
        vlcPlayer.onEndReached = { [weak self] in
            guard let self, self.playbackBackend == .vlc else { return }
            self.handlePlaybackFinished()
        }
    }

    private func bindNativePlayer() {
        nativeTimeObserver = nativePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackBackend == .native else { return }
                let seconds = time.seconds
                
                // Stall detection: if playing but time isn't moving
                if !self.isPaused && !self.isSeeking && seconds.isFinite && seconds > 0 {
                    if seconds == self.lastStallPosition {
                        self.nativeStallCount += 1
                        if self.nativeStallCount > 30 { // ~3 seconds stall
                            self.nativeStallCount = 0
                            print("检测到原生播放器卡死 (Position: \(seconds))，尝试切至 mpv 内核...")
                            self.selectBackend(.mpv)
                        }
                    } else {
                        self.nativeStallCount = 0
                        self.lastStallPosition = seconds
                    }
                } else {
                    self.nativeStallCount = 0
                }

                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                if Int(self.currentTime) % 1 == 0 {
                    self.saveCurrentProgress()
                }
            }
        }

        if let observer = nativeEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        nativeEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackBackend == .native else { return }
                let notificationItem = notification.object as? AVPlayerItem
                let currentItem = self.nativePlayer.currentItem
                print("[BZPlayer] Native player did play to end time - notification item: \(String(describing: notificationItem)), current item: \(String(describing: currentItem)), match: \(notificationItem === currentItem)")
                self.handlePlaybackFinished()
            }
        }
    }

    private func selectBackend(_ backend: PlaybackBackend) {
        let previousBackend = playbackBackend
        playbackBackend = backend

        // Extensive cleanup for previous backends to prevent cross-engine interference and crashes
        if previousBackend == .mpv {
            mpvPlayer.stop()
            mpvPlayer.cancelPendingRender()
        }

        if previousBackend == .native {
            nativePlayer.pause()
            nativeItemStatusObserver = nil
            nativePlayer.replaceCurrentItem(with: nil)
        }

        if previousBackend == .vlc {
            vlcPlayer.stop()
            vlcPlayer.cancelPendingRender()
        }

        switch backend {
        case .native:
            playbackEngineStatus = "AVPlayer"
            syncText = "播放链路：系统原生"
            nativePlayer.volume = Float(volume / 100.0)
            nativePlayer.isMuted = isMuted
        case .mpv:
            playbackEngineStatus = "mpv/libmpv"
            syncText = "播放链路：mpv/libmpv"
            mpvPlayer.setSubtitleBackgroundOpacity(subtitleBackgroundOpacity)
            if let selectedSubtitlePath {
                mpvPlayer.setExternalSubtitle(url: URL(fileURLWithPath: selectedSubtitlePath))
            }
        case .vlc:
            playbackEngineStatus = "VLC/libvlc"
            syncText = "播放链路：VLC/libvlc"
            vlcPlayer.setVolume(volume)
            vlcPlayer.setMuted(isMuted)
        }
    }

    private func openFromPlaylist(_ url: URL, forceStartAtBeginning: Bool = false) {
        debugLog("[BZPlayer] openFromPlaylist: \(url.lastPathComponent), forceStartAtBeginning: \(forceStartAtBeginning)")
        // Clear previous error and reset backend switch flag
        playbackError = nil
        attemptedBackendSwitch = false
        mpvAttemptedSoftwareFallback = false
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil

        // IMPORTANT: If loopMode was set to .none due to playback failure, restore it
        // We detect this by checking if it was changed while a playbackError existed
        if loopMode == .none && playbackError == nil {
            let settings = Self.loadSettings()
            loopMode = LoopMode(rawValue: settings.loopMode) ?? .playlist
            debugLog("[BZPlayer] Restored loop mode to: \(loopMode)")
        }

        isPaused = false
        saveCurrentProgress()
        // Capture whether a file was already playing before this open call
        let isFirstOpen = currentFileURL == nil
        currentFileURL = url
        openedFilePath = url.path
        addRecentFile(url)
        currentIndex = playlist.firstIndex(of: url) ?? -1
        currentTime = 0
        duration = 0
        currentVideoSize = estimateVideoSize(for: url)
        currentNominalFPS = estimateFPS(for: url)
        let discoveredSubtitles = discoverSubtitleFiles(for: url)
        selectedSubtitlePath = pickDefaultSubtitle(for: url, from: discoveredSubtitles)?.path
        updateWindowTitle(url.lastPathComponent)
        showToastMessage(url.lastPathComponent)
        // Only apply window behavior on first file open (isFirstOpen = true means no file was playing before).
        // For videoSize/fitLargest modes, always adjust window to match video content.
        // For maximized/fullscreen/rememberLast, only adjust on first open to avoid resetting the window
        // position/size every time the user switches to a new file from Finder.
        applyWindowBehaviorForCurrentMedia(isFirstOpen: isFirstOpen)

        // 恢复该文件记忆的速度
        if isFirstOpen {
            // 首次打开：用文件独立速度或全局记忆速度
            if let savedSpeed = loadSpeedForFile(url) {
                speed = savedSpeed
                debugLog("[BZPlayer] Restored speed for file: \(savedSpeed)")
            } else {
                let lastUsed = Self.loadSettings().lastUsedSpeed
                speed = lastUsed
                saveSpeedForFile(url)
                debugLog("[BZPlayer] Inherited last used speed: \(lastUsed)")
            }
        } else {
            // 同一窗口切换：保持当前速度，并保存为新文件的独立速度
            saveSpeedForFile(url)
            debugLog("[BZPlayer] Keeping current speed: \(speed) for new file")
        }

        // 恢复该文件记忆的音频延迟
        if let savedAudioDelay = loadAudioDelayForFile(url) {
            audioDelayMs = savedAudioDelay
        } else {
            audioDelayMs = 0
        }

        let resumeTime = forceStartAtBeginning ? nil : loadSavedProgress(for: url)
        debugLog("[BZPlayer] resumeTime: \(resumeTime ?? -1)")
        let ffprobeInfo = probeMediaInfo(url: url)
        let backend = chooseBackend(for: url, ffprobeInfo: ffprobeInfo)
        debugLog("[BZPlayer] Selected backend: \(backend)")
        selectBackend(backend)

        switch backend {
        case .native:
            let needsNativeWarmupReload = shouldRefreshNativeVideoSurface(url: url, ffprobeInfo: ffprobeInfo)
            let shouldWarmupThroughMpv = needsNativeWarmupReload && !Self.hasCompletedNativeVP9Warmup
            if shouldWarmupThroughMpv {
                warmupNativeVP9PlaybackThroughMpv(url: url, resumeAt: resumeTime, startPaused: false)
            } else {
                openWithNative(
                    url: url,
                    resumeAt: resumeTime,
                    refreshVideoSurfaceAfterReady: needsNativeWarmupReload,
                    reloadItemAfterReady: needsNativeWarmupReload
                )
            }
        case .mpv:
            mpvPlayer.setHardwareDecodingEnabled(true)
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: url, resumeAt: resumeTime)
            mpvPlayer.play()
            applyAudioDelay()  // 应用文件记忆的音频延迟
        case .vlc:
            vlcPlayer.setSpeed(speed)
            vlcPlayer.load(url: url, resumeAt: resumeTime)
            vlcPlayer.play()
        }

        // Schedule a failure check after 5 seconds
        schedulePlaybackFailureCheck(for: url, backend: backend, resumeAt: resumeTime)
    }

    private func schedulePlaybackFailureCheck(for url: URL, backend: PlaybackBackend, resumeAt: Double?) {
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkAndHandlePlaybackFailure(for: url, originalBackend: backend, resumeAt: resumeAt)
            }
        }
    }

    private func checkAndHandlePlaybackFailure(for url: URL, originalBackend: PlaybackBackend, resumeAt: Double?) {
        // If duration is still 0 and we're paused or at time 0, playback likely failed
        let hasFailed = duration == 0 && (isPaused || currentTime < 0.5)

        guard hasFailed else { return }

        if originalBackend == .mpv && !mpvAttemptedSoftwareFallback {
            mpvAttemptedSoftwareFallback = true
            print("[BZPlayer] Playback failed with mpv hardware decoding, falling back to software decoding")
            mpvPlayer.setHardwareDecodingEnabled(false)
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: url, resumeAt: resumeAt)
            mpvPlayer.play()
            schedulePlaybackFailureCheck(for: url, backend: .mpv, resumeAt: resumeAt)
            return
        }

        if !attemptedBackendSwitch {
            // Try switching to the other backend
            attemptedBackendSwitch = true
            let newBackend: PlaybackBackend
            switch originalBackend {
            case .native: newBackend = .mpv
            case .mpv:    newBackend = .native
            case .vlc:    newBackend = .mpv
            }
            print("[BZPlayer] Playback failed with \(originalBackend), switching to \(newBackend)")

            selectBackend(newBackend)

            switch newBackend {
            case .native:
                openWithNative(url: url, resumeAt: resumeAt, refreshVideoSurfaceAfterReady: shouldRefreshNativeVideoSurface(url: url))
            case .mpv:
                mpvAttemptedSoftwareFallback = false
                mpvPlayer.setHardwareDecodingEnabled(true)
                mpvPlayer.setSpeed(speed)
                mpvPlayer.load(url: url, resumeAt: resumeAt)
                mpvPlayer.play()
            case .vlc:
                vlcPlayer.setSpeed(speed)
                vlcPlayer.load(url: url, resumeAt: resumeAt)
                vlcPlayer.play()
            }

            // Schedule another check after switching backend
            schedulePlaybackFailureCheck(for: url, backend: newBackend, resumeAt: resumeAt)
        } else {
            // All tried backends failed, show error and file info
            let errorMsg = "无法播放文件：\(url.lastPathComponent)\n多个播放内核都无法解码此文件。"
            print("[BZPlayer] \(errorMsg)")
            playbackError = errorMsg

            // Stop auto-advance and show file info
            if loopMode != .none {
                print("[BZPlayer] Stopping playback sequence due to unplayable file")
                loopMode = .none
            }

            // Show file info panel
            showFileInfo()
        }
    }

    private func openWithNative(
        url: URL,
        resumeAt: Double?,
        startPaused: Bool = false,
        refreshVideoSurfaceAfterReady: Bool = false,
        reloadItemAfterReady: Bool = false
    ) {
        let item = AVPlayerItem(url: url)
        nativeItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackBackend == .native else { return }
                if item.status == .readyToPlay {
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite ? max(0, seconds) : 0
                    self.syncText = "播放链路：系统原生"
                    self.playbackEngineStatus = "AVPlayer"
                    if let resumeAt, resumeAt > 0 {
                        self.nativePlayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                    }
                    if startPaused {
                        self.nativePlayer.pause()
                        self.isPaused = true
                    } else {
                        self.nativePlayer.play()
                        self.nativePlayer.rate = Float(self.speed)
                        self.isPaused = false
                    }
                    if refreshVideoSurfaceAfterReady {
                        self.refreshNativeVideoSurface()
                    }
                    if reloadItemAfterReady {
                        self.reloadNativeItemAfterWarmup(url: url, resumeAt: resumeAt, startPaused: startPaused)
                    }
                }
            }
        }
        nativePlayer.replaceCurrentItem(with: item)
    }

    private func chooseBackend(for url: URL, ffprobeInfo: FFprobeInfo? = nil) -> PlaybackBackend {
        // MKV, AVI and other containers are not natively supported by AVPlayer on macOS
        let nonNativeContainers: Set<String> = [
            "mkv", "avi", "flv", "wmv", "webm", "rmvb", "ts", "mpeg", "mpg",
            "ogg", "oga", "opus", "wma", "ape", "mka"
        ]
        if nonNativeContainers.contains(url.pathExtension.lowercased()) {
            return .mpv
        }

        let asset = AVURLAsset(url: url)
        let ffprobeInfo = ffprobeInfo ?? probeMediaInfo(url: url)

        if let ffprobeInfo, shouldPreferMpv(ffprobeInfo: ffprobeInfo) {
            return .mpv
        }

        if shouldPreferMpv(asset: asset) {
            return .mpv
        }

        if let ffprobeInfo, !ffprobeInfo.audioStreams.isEmpty {
            let audioTracks = asset.tracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                return .mpv
            }
        }

        return .native
    }

    private func shouldPreferMpv(ffprobeInfo: FFprobeInfo) -> Bool {
        let nativeSafeVideoCodecs: Set<String> = [
            "h264", "hevc", "mpeg4", "mjpeg", "prores", "jpeg2000", "dvvideo", "h263", "av1", "vp9"
        ]
        
        // VP9 may be supported on modern macOS in MP4/WebM containers, but WebM is usually routed to mpv due to container check.
        // AVC/HEVC tags like avc1, hvc1, hev1 are natively supported.
        let nativeUnsafeVideoTags: Set<String> = []

        if ffprobeInfo.videoStreams.contains(where: { stream in
            if !nativeSafeVideoCodecs.contains(stream.codecName) { return true }
            if nativeUnsafeVideoTags.contains(stream.codecTag) { return true }
            return false
        }) {
            return true
        }

        let nativeSafeAudioCodecs: Set<String> = [
            "aac", "ac3", "eac3", "alac", "mp3", "opus", "flac",
            "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le", "pcm_u8",
            "pcm_s16be", "pcm_s24be", "pcm_s32be"
        ]

        if ffprobeInfo.audioStreams.contains(where: { !nativeSafeAudioCodecs.contains($0.codecName) }) {
            return true
        }

        return false
    }

    private func shouldPreferMpv(asset: AVURLAsset) -> Bool {
        let nativeSafeVideoSubtypes: Set<String> = [
            "avc1", "hvc1", "hev1", "mp4v", "jpeg", "mjp2", "apcn", "apcs", "apco", "apch", "ap4h", "dvc ",
            "vp09", "vp9 ", "90pv"
        ]
        let nativeSafeAudioSubtypes: Set<String> = [
            "aac ", "ac-3", "ec-3", "alac", ".mp3", "mp4a",
            "lpcm", "twos", "sowt", "fl32", "fl64", "in24", "in32",
            "opus", "supo"
        ]

        for track in asset.tracks(withMediaType: .video) {
            for formatDescription in track.formatDescriptions {
                let subtype = codecSubtypeString(from: formatDescription)
                if !subtype.isEmpty && !nativeSafeVideoSubtypes.contains(subtype) { return true }
            }
        }

        for track in asset.tracks(withMediaType: .audio) {
            for formatDescription in track.formatDescriptions {
                let subtype = codecSubtypeString(from: formatDescription)
                if !subtype.isEmpty && !nativeSafeAudioSubtypes.contains(subtype) { return true }
            }
        }

        return false
    }

    private func codecSubtypeString(from formatDescription: Any) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
        return fourCCString(subtype).lowercased()
    }

    private func shouldRefreshNativeVideoSurface(url: URL, ffprobeInfo: FFprobeInfo? = nil) -> Bool {
        if let ffprobeInfo, ffprobeInfo.videoStreams.contains(where: { $0.codecName == "vp9" }) {
            return true
        }

        let asset = AVURLAsset(url: url)
        let vp9Subtypes: Set<String> = ["vp09", "vp9 ", "90pv"]
        return asset.tracks(withMediaType: .video).contains { track in
            track.formatDescriptions.contains { formatDescription in
                vp9Subtypes.contains(codecSubtypeString(from: formatDescription))
            }
        }
    }

    private func refreshNativeVideoSurface() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.playbackBackend == .native else { return }
            debugLog("[BZPlayer] Refreshing native video surface")
            self.nativePlayerSurfaceRefreshID += 1
        }
    }

    private func reloadNativeItemAfterWarmup(url: URL, resumeAt: Double?, startPaused: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.playbackBackend == .native, self.currentFileURL == url else { return }

            let currentSeconds = self.nativePlayer.currentTime().seconds
            let reloadResumeAt: Double?
            if currentSeconds.isFinite, currentSeconds > 0 {
                reloadResumeAt = currentSeconds
            } else {
                reloadResumeAt = resumeAt
            }

            debugLog("[BZPlayer] Reloading native VP9 item after AV warmup")
            self.nativeItemStatusObserver = nil
            self.nativePlayer.replaceCurrentItem(with: nil)
            self.openWithNative(
                url: url,
                resumeAt: reloadResumeAt,
                startPaused: startPaused,
                refreshVideoSurfaceAfterReady: true,
                reloadItemAfterReady: false
            )
        }
    }

    private func warmupNativeVP9PlaybackThroughMpv(url: URL, resumeAt: Double?, startPaused: Bool) {
        Self.hasCompletedNativeVP9Warmup = true
        debugLog("[BZPlayer] Warming native VP9 playback through mpv roundtrip")
        selectBackend(.mpv)
        mpvAttemptedSoftwareFallback = false
        mpvPlayer.setHardwareDecodingEnabled(true)
        mpvPlayer.setSpeed(speed)
        mpvPlayer.load(url: url, resumeAt: resumeAt)
        if startPaused {
            mpvPlayer.pause()
        } else {
            mpvPlayer.play()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            guard self.currentFileURL == url, self.playbackBackend == .mpv else { return }

            let mpvTime = self.mpvPlayer.getDoubleProperty("time-pos")
            let nativeResumeAt = (mpvTime?.isFinite == true && (mpvTime ?? 0) > 0) ? mpvTime : resumeAt
            debugLog("[BZPlayer] Returning to native after VP9 warmup")
            self.selectBackend(.native)
            self.openWithNative(
                url: url,
                resumeAt: nativeResumeAt,
                startPaused: startPaused,
                refreshVideoSurfaceAfterReady: true,
                reloadItemAfterReady: true
            )
        }
    }

    private func loadPlaylist(with selectedURL: URL) {
        let fm = FileManager.default
        let folder = selectedURL.deletingLastPathComponent()
        let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "flv", "wmv", "m4v", "webm", "ts", "mpeg", "mpg"]

        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let allVideos = urls.filter { videoExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        playlist = allVideos.isEmpty ? [selectedURL] : allVideos
        currentIndex = playlist.firstIndex(of: selectedURL) ?? 0
        if playlistOrder == .descending {
            playlist.reverse()
            currentIndex = playlist.firstIndex(of: selectedURL) ?? 0
        }
    }

    private func moveInPlaylist(step: Int) {
        guard !playlist.isEmpty else { return }
        let currentURL = currentFileURL ?? (playlist.indices.contains(currentIndex) ? playlist[currentIndex] : playlist.first!)
        let current = playlist.firstIndex(of: currentURL) ?? currentIndex
        guard current >= 0 else { return }
        let next = current + step
        guard playlist.indices.contains(next) else { return }
        openFromPlaylist(playlist[next])
    }

    private func estimateFPS(for url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .video).first {
            let fps = Double(track.nominalFrameRate)
            if fps.isFinite, fps > 0 {
                return fps
            }
        }
        if let ffprobeInfo = probeMediaInfo(url: url),
           let summary = ffprobeInfo.videoStreams.first?.summary,
           let fps = parseFPS(fromFFprobeSummary: summary) {
            return fps
        }
        return 30
    }

    private func estimateVideoSize(for url: URL) -> CGSize? {
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .video).first {
            let transformed = track.naturalSize.applying(track.preferredTransform)
            let width = abs(transformed.width.rounded())
            let height = abs(transformed.height.rounded())
            if width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }
        return nil
    }

    static var appVersion: String {
        if let info = Bundle.main.infoDictionary,
           let version = info["CFBundleVersion"] as? String,
           !version.isEmpty {
            return version
        }
        return "dev"
    }

    static var defaultWindowTitle: String {
        "BZPlayer (\(appVersion))"
    }

    private func updateWindowTitle(_ title: String) {
        windowTitle = "\(title) (\(Self.appVersion))"
        attachedWindow?.title = windowTitle
    }

    private func loadSavedProgress(for url: URL) -> Double? {
        let settings = loadFileSettings(for: url)
        return settings.progress > 0 ? settings.progress : nil
    }

    private func saveCurrentProgress() {
        guard let url = currentFileURL, currentTime.isFinite, currentTime > 0 else { return }
        if duration > 0 && currentTime >= max(duration - 0.5, 0) {
            return
        }
        var fileSettings = loadFileSettings(for: url)
        fileSettings.progress = currentTime
        saveFileSettings(for: url, fileSettings)
    }

    private func clearSavedProgress(for url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.progress = 0
        saveFileSettings(for: url, fileSettings)
    }

    private func loadSpeedForFile(_ url: URL) -> Double? {
        let settings = loadFileSettings(for: url)
        return settings.speed > 0 ? settings.speed : nil
    }

    private func saveSpeedForFile(_ url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.speed = speed
        saveFileSettings(for: url, fileSettings)
    }

    private func loadAudioDelayForFile(_ url: URL) -> Double? {
        let settings = loadFileSettings(for: url)
        return settings.audioDelayMs != 0 ? settings.audioDelayMs : nil
    }

    private func saveAudioDelayForFile(_ url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.audioDelayMs = audioDelayMs
        saveFileSettings(for: url, fileSettings)
    }

    private func showToastMessage(_ message: String) {
        toastMessage = message
        showToast = true
        // 3秒后自动隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.showToast = false
        }
    }

    func fetchPlaylistDuration(for url: URL) async {
        if playlistDurations[url] != nil { return }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite {
                playlistDurations[url] = seconds
            }
        } catch {
            debugLog("Failed to fetch duration for \(url): \(error)")
        }
    }

    func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyInitialWindowBehaviorIfNeeded(force: Bool = false) {
        guard let attachedWindow else { return }
        guard force || !hasAppliedInitialWindowBehavior else { return }
        hasAppliedInitialWindowBehavior = true

        switch windowOpenBehavior {
        case .fullscreen:
            enterFullscreenIfNeeded(for: attachedWindow)
        case .maximized:
            maximize(window: attachedWindow)
        case .rememberLast:
            if !restoreRememberedWindowFrame(on: attachedWindow) {
                maximize(window: attachedWindow)
            }
        case .videoSize, .fitLargest:
            break
        }
    }

    private func applyWindowBehaviorForCurrentMedia(isFirstOpen: Bool = true) {
        guard let attachedWindow else { return }
        switch windowOpenBehavior {
        case .fullscreen:
            // Only enter fullscreen on first file open, don't re-fullscreen on every file switch
            if isFirstOpen { enterFullscreenIfNeeded(for: attachedWindow) }
        case .maximized:
            // Only maximize on first file open
            if isFirstOpen { maximize(window: attachedWindow) }
        case .videoSize:
            // Always resize to match video dimensions
            resizeWindowToVideoSize(attachedWindow)
        case .rememberLast:
            if isFirstOpen {
                if !restoreRememberedWindowFrame(on: attachedWindow) {
                    resizeWindowToLargestFit(attachedWindow)
                }
            }
        case .fitLargest:
            // Always resize to fit video
            resizeWindowToLargestFit(attachedWindow)
        }
    }

    private func maximize(window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        exitFullscreenIfNeeded(window) {
            let frame = screen.visibleFrame
            window.setFrame(frame, display: true, animate: true)
            self.persistWindowFrameIfNeeded(window)
        }
    }

    private func resizeWindowToVideoSize(_ window: NSWindow) {
        guard let videoSize = currentVideoSize, let screen = window.screen ?? NSScreen.main else { return }
        exitFullscreenIfNeeded(window) {
            let visible = screen.visibleFrame
            let maxContentWidth = max(visible.width * 0.9, 400)
            let maxContentHeight = max(visible.height * 0.9, 300)
            let width = min(videoSize.width, maxContentWidth)
            let height = min(videoSize.height, maxContentHeight)
            self.resize(window: window, contentSize: CGSize(width: width, height: height))
        }
    }

    private func resizeWindowToLargestFit(_ window: NSWindow) {
        guard let videoSize = currentVideoSize, let screen = window.screen ?? NSScreen.main else { return }
        exitFullscreenIfNeeded(window) {
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let scale = min(visible.width / videoSize.width, visible.height / videoSize.height)
            let fitted = CGSize(
                width: max(min(videoSize.width * scale, visible.width), 400),
                height: max(min(videoSize.height * scale, visible.height), 300)
            )
            self.resize(window: window, contentSize: fitted)
        }
    }

    private func resize(window: NSWindow, contentSize: CGSize) {
        let clamped = CGSize(width: max(contentSize.width, 980), height: max(contentSize.height, 620))
        let frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: clamped))
        guard let screen = window.screen ?? NSScreen.main else {
            window.setContentSize(clamped)
            persistWindowFrameIfNeeded(window)
            return
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        )
        window.setFrame(CGRect(origin: origin, size: frame.size), display: true, animate: true)
        persistWindowFrameIfNeeded(window)
    }

    private func enterFullscreenIfNeeded(for window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func exitFullscreenIfNeeded(_ window: NSWindow, completion: @escaping () -> Void) {
        guard window.styleMask.contains(.fullScreen) else {
            completion()
            return
        }
        window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            completion()
        }
    }

    private func restoreRememberedWindowFrame(on window: NSWindow) -> Bool {
        let settings = Self.loadSettings()
        guard let frameString = settings.lastWindowFrame else { return false }
        let frame = NSRectFromString(frameString)
        guard !frame.isEmpty else { return false }
        exitFullscreenIfNeeded(window) {
            window.setFrame(frame, display: true, animate: true)
            self.persistWindowFrameIfNeeded(window)
        }
        return true
    }

    private func installWindowFrameObservers(for window: NSWindow) {
        removeWindowFrameObservers()
        let center = NotificationCenter.default
        let moveObserver = center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let self, let window else { return }
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.persistWindowFrameIfNeeded(window)
            }
        }
        let resizeObserver = center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let self, let window else { return }
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.persistWindowFrameIfNeeded(window)
            }
        }
        windowFrameObservers = [moveObserver, resizeObserver]
    }

    private func removeWindowFrameObservers() {
        let center = NotificationCenter.default
        for observer in windowFrameObservers {
            center.removeObserver(observer)
        }
        windowFrameObservers.removeAll()
    }

    private func persistWindowFrameIfNeeded(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        saveSettings()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func buildFileInfoText(url: URL) async -> String {
        let asset = AVURLAsset(url: url)
        do {
            let durationTime = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            let fileSizeBytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let ffprobeInfo = probeMediaInfo(url: url)
            let recommendedBackend = chooseBackend(for: url, ffprobeInfo: ffprobeInfo)

            var lines: [String] = []
            lines.append("文件：\(url.lastPathComponent)")
            lines.append("路径：\(url.path)")
            if let fileSizeBytes {
                lines.append("大小：\(formatBytes(Int64(fileSizeBytes)))")
            }

            let durationSeconds = durationTime.seconds
            if durationSeconds.isFinite, durationSeconds > 0 {
                lines.append("时长：\(formatDuration(durationSeconds)) (\(String(format: "%.2f", durationSeconds)) 秒)")
            }

            lines.append("建议播放后端：\(recommendedBackend == .native ? "系统原生" : "mpv/libmpv")")
            if let ffprobeInfo {
                if !ffprobeInfo.videoStreams.isEmpty {
                    lines.append("视频编码：\(codecHeadline(from: ffprobeInfo.videoStreams))")
                }
                if !ffprobeInfo.audioStreams.isEmpty {
                    lines.append("音频编码：\(codecHeadline(from: ffprobeInfo.audioStreams))")
                }
            }

            let videoTracks = tracks.filter { $0.mediaType == .video }
            lines.append("")
            lines.append("视频轨道：\(videoTracks.count)")
            for (index, videoTrack) in videoTracks.enumerated() {
                let size = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                let fps = try await videoTrack.load(.nominalFrameRate)
                let estimatedBitRate = try await videoTrack.load(.estimatedDataRate)

                let transformed = size.applying(transform)
                let width = abs(Int(transformed.width.rounded()))
                let height = abs(Int(transformed.height.rounded()))

                lines.append("")
                lines.append("【视频 #\(index + 1)】")
                lines.append("分辨率：\(width)x\(height)")
                lines.append("帧率：\(String(format: "%.3f", fps)) fps")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                lines.append("编码：\(codecDescription(from: videoTrack.formatDescriptions.first, mediaType: "视频"))")
            }

            let audioTracks = tracks.filter { $0.mediaType == .audio }
            lines.append("")
            lines.append("音频轨道：\(audioTracks.count)")
            if audioTracks.isEmpty {
                if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
                    lines.append("提示：AVFoundation 未识别到音轨，但 ffprobe 检测到 \(ffprobeInfo.audioStreams.count) 条音轨。")
                    lines.append("这类文件会自动切到 mpv 后端播放。")
                } else {
                    lines.append("提示：AVFoundation 未检测到音轨。")
                    lines.append("若文件在其它播放器有声音，更可能是当前系统媒体解析兼容性问题。")
                    lines.append("本次未拿到 ffprobe 音轨结果，可能是 ffprobe 不可用、执行失败，或文件读取受限。")
                    lines.append("因此这里不能据此判断源文件就是无声。")
                }
            }

            for (index, audioTrack) in audioTracks.enumerated() {
                let estimatedBitRate = try await audioTrack.load(.estimatedDataRate)
                lines.append("")
                lines.append("【音频 #\(index + 1)】")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                if let formatDesc = audioTrack.formatDescriptions.first.map({ $0 as! CMFormatDescription }),
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                    lines.append("采样率：\(Int(asbd.mSampleRate)) Hz")
                    lines.append("声道数：\(asbd.mChannelsPerFrame)")
                    lines.append("位深：\(asbd.mBitsPerChannel) bit")
                }
                lines.append("编码：\(codecDescription(from: audioTrack.formatDescriptions.first, mediaType: "音频"))")
            }

            if let ffprobeInfo {
                lines.append("")
                lines.append("【ffprobe 检测】")
                lines.append("视频流：\(ffprobeInfo.videoStreams.count)")
                for (index, stream) in ffprobeInfo.videoStreams.enumerated() {
                    lines.append("视频 #\(index + 1)：\(stream.summary)")
                }
                lines.append("音频流：\(ffprobeInfo.audioStreams.count)")
                for (index, stream) in ffprobeInfo.audioStreams.enumerated() {
                    lines.append("音频 #\(index + 1)：\(stream.summary)")
                }
            }

            return lines.joined(separator: "\n")
        } catch {
            return "读取媒体信息失败：\(error.localizedDescription)"
        }
    }

    private func handlePlaybackFinished() {
        // Capture currentTime before any state changes to ensure accurate end-of-video detection
        let snapshotTime = currentTime
        debugLog("[BZPlayer] handlePlaybackFinished called - Time: \(snapshotTime), Duration: \(duration), isPaused: \(isPaused), isSeeking: \(isSeeking), loopMode: \(loopMode)")

        // Don't auto-advance if there's a playback error
        if playbackError != nil {
            debugLog("[BZPlayer] Playback error detected, pausing instead of auto-advancing")
            isPaused = true
            return
        }

        // If duration is 0, try to get it directly from mpv
        var effectiveDuration = duration
        if effectiveDuration == 0 && playbackBackend == .mpv {
            if let mpvDuration = mpvPlayer.getDoubleProperty("duration") {
                effectiveDuration = mpvDuration
                debugLog("[BZPlayer] Got duration from mpv directly: \(effectiveDuration)")
            }
        }
        if effectiveDuration == 0 && playbackBackend == .vlc {
            if let vlcDuration = vlcPlayer.getDoubleProperty("duration") {
                effectiveDuration = vlcDuration
                debugLog("[BZPlayer] Got duration from VLC directly: \(effectiveDuration)")
            }
        }

        // Integrity Check: Only trigger auto-next if we are ACTUALLY near the end and have valid duration.
        // This prevents infinite loops caused by unexpected EOF notifications during item resets.
        // Use snapshotTime (captured before any reset) so that currentTime=0 races don't break detection.
        let timeDiff = abs(snapshotTime - effectiveDuration)
        let progressPercent = effectiveDuration > 0 ? snapshotTime / effectiveDuration : 0
        // isNearEnd: either within 5 seconds of end, OR past 90% of duration
        // NOTE: effectiveDuration must be > 0, otherwise it's likely a playback failure
        let isNearEnd = effectiveDuration > 0 && (timeDiff < 5.0 || progressPercent >= 0.9)

        debugLog("[BZPlayer] isNearEnd check - duration: \(effectiveDuration), snapshotTime: \(snapshotTime), timeDiff: \(timeDiff), progressPercent: \(progressPercent), result: \(isNearEnd)")
        guard isNearEnd else {
            debugLog("[BZPlayer] Ignoring playback-finished notification (not near end or invalid duration)")
            // If duration is 0, this might be a playback failure - don't auto-advance
            if effectiveDuration == 0 {
                debugLog("[BZPlayer] Duration is 0, treating as playback failure - stopping auto-advance")
                isPaused = true
            }
            return
        }

        // Clear saved progress AFTER guard (we're truly at end), and reset currentTime
        if let url = currentFileURL {
            clearSavedProgress(for: url)
        }
        currentTime = 0

        // Safety Guard: prevent rapid-fire infinite auto-next loops
        let now = ProcessInfo.processInfo.systemUptime
        lastAutoNextJumpTimes = lastAutoNextJumpTimes.filter { now - $0 < 5.0 }
        lastAutoNextJumpTimes.append(now)

        if lastAutoNextJumpTimes.count > 5 {
            debugLog("[BZPlayer] DETECTED INFINITE SKIP LOOP! Pausing playback to prevent instability.")
            pause()
            lastAutoNextJumpTimes.removeAll()
            showAlert(title: "播放提示", message: "检测到连续快速切片，可能遇到无法播放的文件，已停止播放以防程序崩溃。")
            return
        }

        // Capture currentFileURL before openFromPlaylist clears/replaces it
        let finishedFileURL = currentFileURL

        switch loopMode {
        case .singleFile:
            debugLog("[BZPlayer] Loop mode: singleFile")
            if let url = finishedFileURL {
                openFromPlaylist(url, forceStartAtBeginning: true)
            } else {
                isPaused = true
            }
        case .playlist:
            debugLog("[BZPlayer] Loop mode: playlist, currentFileURL: \(String(describing: finishedFileURL)), currentIndex: \(currentIndex)")
            // Use path comparison to find current index, as URL instances may differ
            let current: Int
            if let currentURL = finishedFileURL {
                current = playlist.firstIndex { $0.path == currentURL.path } ?? currentIndex
            } else {
                current = currentIndex
            }
            debugLog("[BZPlayer] Calculated current index: \(current), playlist.count: \(playlist.count)")
            let nextIndex = current + 1
            if nextIndex < playlist.count {
                debugLog("[BZPlayer] Opening next file at index \(nextIndex): \(playlist[nextIndex].lastPathComponent)")
                openFromPlaylist(playlist[nextIndex])
            } else if let first = playlist.first {
                debugLog("[BZPlayer] At end of playlist, looping back to first: \(first.lastPathComponent)")
                openFromPlaylist(first)
            } else {
                debugLog("[BZPlayer] Playlist is empty, pausing")
                isPaused = true
            }
        case .none:
            debugLog("[BZPlayer] Loop mode: none, pausing")
            isPaused = true
        }
    }
}

private extension PlayerViewModel {
    static func clampSubtitleOpacity(_ value: Int) -> Int {
        let candidates = [0, 25, 50, 75, 100]
        if candidates.contains(value) {
            return value
        }
        if value <= 0 { return 0 }
        if value >= 100 { return 100 }
        return candidates.min(by: { abs($0 - value) < abs($1 - value) }) ?? 0
    }

    func discoverSubtitleFilesForCurrentMedia() -> [URL] {
        guard let mediaURL = currentFileURL else { return [] }
        return discoverSubtitleFiles(for: mediaURL)
    }

    func discoverSubtitleFiles(for mediaURL: URL) -> [URL] {
        let folderURL = mediaURL.deletingLastPathComponent()
        let mediaBase = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx"]

        let files = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return files.filter { url in
            let ext = url.pathExtension.lowercased()
            guard subtitleExtensions.contains(ext) else { return false }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            return stem.hasPrefix(mediaBase)
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func pickDefaultSubtitle(for mediaURL: URL, from candidates: [URL]) -> URL? {
        let mediaBase = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let exactMatches = candidates.filter {
            $0.deletingPathExtension().lastPathComponent.lowercased() == mediaBase
        }
        if exactMatches.isEmpty { return nil }

        let extPriority: [String: Int] = [
            "srt": 0,
            "ass": 1,
            "ssa": 2,
            "vtt": 3,
            "sub": 4,
            "idx": 5
        ]
        return exactMatches.sorted {
            let leftExt = $0.pathExtension.lowercased()
            let rightExt = $1.pathExtension.lowercased()
            let leftOrder = extPriority[leftExt] ?? Int.max
            let rightOrder = extPriority[rightExt] ?? Int.max
            if leftOrder == rightOrder {
                return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            return leftOrder < rightOrder
        }.first
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}

private func formatDuration(_ time: Double) -> String {
    let total = Int(time)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
