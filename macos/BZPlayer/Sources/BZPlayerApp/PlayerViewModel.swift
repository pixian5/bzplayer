import AVFoundation
import AVKit
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers
import VLCKitSPM
import BZPlayerCore

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    struct SubtitleMenuEntry {
        let title: String
        let path: String?
        let isSelected: Bool
    }

    struct TrackMenuEntry {
        let id: Int32
        let name: String
        let isSelected: Bool
    }

    enum PlaybackBackend: String {
        case native
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
    @Published var numericKeySpeeds: [Double]
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
    @Published var audioOnlyWhenMinimized: Bool
    @Published private(set) var isAudioOnlyMode = false
    @Published var subtitleBackgroundOpacity: Int
    @Published var subtitleFontSize: Int
    /// Native subtitle center X in host width fraction (0=left, 0.5=center, 1=right).
    @Published var subtitlePositionX: Double
    /// Native subtitle center Y in host height fraction measured from bottom (0=bottom, 1=top).
    @Published var subtitlePositionY: Double
    /// Active external subtitle line rendered by the native (AVPlayer) overlay.
    @Published private(set) var nativeSubtitleText: String = ""
    /// Bumps when native subtitle overlay content/style changes so NSViewRepresentable refreshes.
    @Published private(set) var nativeSubtitleRenderID: Int = 0
    @Published var appLanguage: String = "auto"
    /// 已打开过但未播完的文件（持久化保存）
    @Published var openedFiles: Set<URL> = []
    /// 已完整播放过的文件（持久化保存）
    @Published var completedFiles: Set<URL> = []
    @Published var playlistDurations: [URL: Double] = [:]
    @Published var nativePlayerSurfaceRefreshID: Int = 0
    @Published var selectedPlaylistIndices = Set<Int>()
    @Published var toastIsSuccess: Bool = false

    var onShowFileInfo: ((String) -> Void)?

    lazy var vlcPlayer = VLCPlayer()
    lazy var nativePlayer = AVPlayer()
    let speedCandidates: [Double] = [0.25, 0.5, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8, 16]
    static let numericSpeedDigits = Array(1...9)
    static let preferencesDidChangeNotification = Notification.Name("BZPlayer.preferencesDidChange")
    static let reservedSpeedKeyCodes: Set<UInt16> = [39, 41]

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

    private(set) var currentFileURL: URL?
    private var currentVideoSize: CGSize?
    private var currentMediaHasAV1Video = false
    private var currentNominalFPS: Double = 30
    private var nativeTimeObserver: Any?
    private var nativeItemStatusObserver: NSKeyValueObservation?
    private var nativeEndObserver: NSObjectProtocol?
    private weak var attachedWindow: NSWindow?
    private static var globalLastNavigationTime: TimeInterval = 0
    private var lastAutoNextJumpTimes: [TimeInterval] = []
    private var windowFrameObservers: [NSObjectProtocol] = []
    private var hasAppliedInitialWindowBehavior = false
    private var nativeStallCount = 0
    private var lastStallPosition: Double = 0
    private var nativePlaybackRefreshGeneration = UUID()
    private var nativePlaybackRefreshInFlight = false
    private var attemptedBackendSwitch = false
    private var playbackFailureTimer: Timer?
    private var mediaAnalysisTask: Task<Void, Never>?
    private var pendingVolumeSaveTask: Task<Void, Never>?
    private var pendingVLCSeekTask: Task<Void, Never>?
    private var pendingSpeedSaveTask: Task<Void, Never>?
    private var pendingWindowFrameSaveTask: Task<Void, Never>?
    private var mediaOpenGeneration = UUID()
    private var activeSeekGeneration = UUID()
    private var playbackInfrastructureInitialized = false
    private static var settingsCache: AppSettings?
    private var selectedSubtitlePath: String?
    /// Parsed external subtitle cues for the native AVPlayer overlay.
    private var nativeSubtitleCues: [ExternalSubtitleCue] = []
    private var nativeSubtitleCueIndex: Int = 0
    private var audioOnlyState: AudioOnlyState?
    private var pendingAudioOnlyAudioTrack: Int32?
    private var pendingAudioOnlySubtitleTrack: Int32?
    private let subtitleCleanupTracker = SubtitleCleanupTracker()
    private static var hasCompletedNativeVP9Warmup = false
    private var vp9WarmupPlayer: AVPlayer?
    private var lastProgressSaveTime: TimeInterval = 0
    private var lastProgressSavePosition: Double = 0
    private let progressSaveInterval: TimeInterval = 5

    private struct AudioOnlyState {
        let url: URL
        let backend: PlaybackBackend
        let time: Double
        let isPaused: Bool
        let speed: Double
        let audioTrack: Int32?
        let subtitleTrack: Int32?
        let nativeVideoTracks: [(AVPlayerItemTrack, Bool)]
    }

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
    private static let subtitleFontSizeKey = "subtitleFontSize"

    private static func normalizeNumericKeySpeeds(_ values: [Double]) -> [Double] {
        numericSpeedDigits.enumerated().map { index, digit in
            let value = index < values.count ? values[index] : Double(digit)
            return normalizeSpeed(value)
        }
    }

    private static func normalizeSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        let clamped = min(max(value, 0.25), 16)
        return (clamped * 100).rounded() / 100
    }

    private static func normalizeVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value, 0), 100)
    }

    private static func normalizeAudioDelay(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func normalizeAudioDelayStep(_ value: Double) -> Double {
        guard value.isFinite else { return 50 }
        return max(value, 1)
    }

    private static func normalizeKeyCode(_ value: Int, fallback: UInt16) -> UInt16 {
        guard (0...Int(UInt16.max)).contains(value) else { return fallback }
        return UInt16(value)
    }

    private static func normalizeUserShortcutKeyCode(_ value: Int, fallback: UInt16) -> UInt16 {
        let normalized = normalizeKeyCode(value, fallback: fallback)
        return reservedSpeedKeyCodes.contains(normalized) ? fallback : normalized
    }

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

    private static var openedFilesURL: URL {
        settingsDir.appendingPathComponent("openedFiles.json")
    }

    private static var completedFilesURL: URL {
        settingsDir.appendingPathComponent("completedFiles.json")
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
        var audioOnlyWhenMinimized: Bool = false
        var subtitleBackgroundOpacity: Int = 0
        var subtitleFontSize: Int = 55
        /// 0...1, center X of native subtitle bubble.
        var subtitlePositionX: Double = 0.5
        /// 0...1 from bottom, center Y of native subtitle bubble.
        var subtitlePositionY: Double = 0.12
        var lastWindowFrame: String? = nil
        var lastUsedSpeed: Double = 1.0
        var appLanguage: String? = "auto"
        var numericKeySpeeds: [Double]?

        private enum CodingKeys: String, CodingKey {
            case shortcutSeekSeconds
            case shortcutFrameStepCount
            case previousFileKeyCode
            case nextFileKeyCode
            case audioStepDownKeyCode
            case audioStepUpKeyCode
            case speedToggleKeyCode
            case playlistOrder
            case loopMode
            case windowOpenBehavior
            case volume
            case isMuted
            case allowMultipleWindows
            case audioDelayMs
            case audioDelayStepMs
            case showRecentFiles
            case audioOnlyWhenMinimized
            case subtitleBackgroundOpacity
            case subtitleFontSize
            case subtitlePositionX
            case subtitlePositionY
            case lastWindowFrame
            case lastUsedSpeed
            case appLanguage
            case numericKeySpeeds
        }

        init() {}

        init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            shortcutSeekSeconds = try container.decodeIfPresent(Double.self, forKey: .shortcutSeekSeconds) ?? shortcutSeekSeconds
            shortcutFrameStepCount = try container.decodeIfPresent(Int.self, forKey: .shortcutFrameStepCount) ?? shortcutFrameStepCount
            previousFileKeyCode = try container.decodeIfPresent(Int.self, forKey: .previousFileKeyCode) ?? previousFileKeyCode
            nextFileKeyCode = try container.decodeIfPresent(Int.self, forKey: .nextFileKeyCode) ?? nextFileKeyCode
            audioStepDownKeyCode = try container.decodeIfPresent(Int.self, forKey: .audioStepDownKeyCode) ?? audioStepDownKeyCode
            audioStepUpKeyCode = try container.decodeIfPresent(Int.self, forKey: .audioStepUpKeyCode) ?? audioStepUpKeyCode
            speedToggleKeyCode = try container.decodeIfPresent(Int.self, forKey: .speedToggleKeyCode) ?? speedToggleKeyCode
            playlistOrder = try container.decodeIfPresent(String.self, forKey: .playlistOrder) ?? playlistOrder
            loopMode = try container.decodeIfPresent(String.self, forKey: .loopMode) ?? loopMode
            windowOpenBehavior = try container.decodeIfPresent(String.self, forKey: .windowOpenBehavior) ?? windowOpenBehavior
            volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? volume
            isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? isMuted
            allowMultipleWindows = try container.decodeIfPresent(Bool.self, forKey: .allowMultipleWindows) ?? allowMultipleWindows
            audioDelayMs = try container.decodeIfPresent(Double.self, forKey: .audioDelayMs) ?? audioDelayMs
            audioDelayStepMs = try container.decodeIfPresent(Double.self, forKey: .audioDelayStepMs) ?? audioDelayStepMs
            showRecentFiles = try container.decodeIfPresent(Bool.self, forKey: .showRecentFiles) ?? showRecentFiles
            audioOnlyWhenMinimized = try container.decodeIfPresent(Bool.self, forKey: .audioOnlyWhenMinimized) ?? audioOnlyWhenMinimized
            subtitleBackgroundOpacity = try container.decodeIfPresent(Int.self, forKey: .subtitleBackgroundOpacity) ?? subtitleBackgroundOpacity
            subtitleFontSize = try container.decodeIfPresent(Int.self, forKey: .subtitleFontSize) ?? subtitleFontSize
            subtitlePositionX = try container.decodeIfPresent(Double.self, forKey: .subtitlePositionX) ?? subtitlePositionX
            subtitlePositionY = try container.decodeIfPresent(Double.self, forKey: .subtitlePositionY) ?? subtitlePositionY
            lastWindowFrame = try container.decodeIfPresent(String.self, forKey: .lastWindowFrame) ?? lastWindowFrame
            lastUsedSpeed = try container.decodeIfPresent(Double.self, forKey: .lastUsedSpeed) ?? lastUsedSpeed
            appLanguage = try container.decodeIfPresent(String.self, forKey: .appLanguage) ?? appLanguage
            numericKeySpeeds = try container.decodeIfPresent([Double].self, forKey: .numericKeySpeeds) ?? numericKeySpeeds
        }
    }

    // MARK: - 单文件设置数据结构（进度/速度/音频延迟）
    private struct FileSettings: Codable {
        var progress: Double = 0
        var speed: Double = 1.0
        var audioDelayMs: Double = 0

        private enum CodingKeys: String, CodingKey {
            case progress
            case speed
            case audioDelayMs
        }

        init() {}

        init(from decoder: Decoder) throws {
            self.init()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? progress
            speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? speed
            audioDelayMs = try container.decodeIfPresent(Double.self, forKey: .audioDelayMs) ?? audioDelayMs
        }
    }

    override convenience init() {
        self.init(loadPlaybackInfrastructure: true)
    }

    init(loadPlaybackInfrastructure: Bool) {
        let settings = Self.loadSettings()
        shortcutSeekSeconds = max(settings.shortcutSeekSeconds, 0.1)
        shortcutFrameStepCount = max(settings.shortcutFrameStepCount, 1)
        previousFileKeyCode = Self.normalizeUserShortcutKeyCode(settings.previousFileKeyCode, fallback: 33)
        nextFileKeyCode = Self.normalizeUserShortcutKeyCode(settings.nextFileKeyCode, fallback: 30)
        audioStepDownKeyCode = Self.normalizeUserShortcutKeyCode(settings.audioStepDownKeyCode, fallback: 43)
        audioStepUpKeyCode = Self.normalizeUserShortcutKeyCode(settings.audioStepUpKeyCode, fallback: 47)
        speedToggleKeyCode = Self.normalizeUserShortcutKeyCode(settings.speedToggleKeyCode, fallback: 24)
        numericKeySpeeds = Self.normalizeNumericKeySpeeds(settings.numericKeySpeeds ?? [])
        playlistOrder = PlaylistOrder(rawValue: settings.playlistOrder) ?? .ascending
        loopMode = LoopMode(rawValue: settings.loopMode) ?? .playlist
        windowOpenBehavior = WindowOpenBehavior(rawValue: settings.windowOpenBehavior) ?? .maximized
        volume = Self.normalizeVolume(settings.volume)
        isMuted = settings.isMuted
        allowMultipleWindows = settings.allowMultipleWindows
        audioDelayMs = Self.normalizeAudioDelay(settings.audioDelayMs)
        audioDelayStepMs = Self.normalizeAudioDelayStep(settings.audioDelayStepMs)
        showRecentFiles = settings.showRecentFiles
        audioOnlyWhenMinimized = settings.audioOnlyWhenMinimized
        subtitleBackgroundOpacity = Self.clampSubtitleOpacity(settings.subtitleBackgroundOpacity)
        subtitleFontSize = max(1, settings.subtitleFontSize)
        subtitlePositionX = Self.clampSubtitlePosition(settings.subtitlePositionX, fallback: 0.5)
        subtitlePositionY = Self.clampSubtitlePosition(settings.subtitlePositionY, fallback: 0.12)
        appLanguage = settings.appLanguage ?? "auto"
        let loadedRecentFiles = Self.loadRecentFilesFromDisk() ?? []
        let filteredRecentFiles = loadedRecentFiles.filter { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        if filteredRecentFiles != loadedRecentFiles {
            Self.saveRecentFilesToDisk(filteredRecentFiles)
        }
        recentFiles = filteredRecentFiles
        openedFiles = Self.loadURLSet(from: Self.openedFilesURL)
        completedFiles = Self.loadURLSet(from: Self.completedFilesURL)
        super.init()

        fileAssociationStatus = t("未执行格式关联")

        guard loadPlaybackInfrastructure else { return }
        playbackInfrastructureInitialized = true
        bindVLCCallbacks()
        bindNativePlayer(for: nativePlayer, generation: mediaOpenGeneration)
        selectBackend(.native)
        warmupVP9DecoderIfNeeded()
    }

    private static func loadSettings() -> AppSettings {
        if let settingsCache {
            return settingsCache
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            let defaults = AppSettings()
            settingsCache = defaults
            return defaults
        }
        settingsCache = settings
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
        settings.volume = Self.normalizeVolume(volume)
        settings.isMuted = isMuted
        settings.allowMultipleWindows = allowMultipleWindows
        settings.audioDelayMs = Self.normalizeAudioDelay(audioDelayMs)
        settings.audioDelayStepMs = Self.normalizeAudioDelayStep(audioDelayStepMs)
        settings.showRecentFiles = showRecentFiles
        settings.audioOnlyWhenMinimized = audioOnlyWhenMinimized
        settings.subtitleBackgroundOpacity = subtitleBackgroundOpacity
        settings.subtitleFontSize = subtitleFontSize
        settings.subtitlePositionX = Self.clampSubtitlePosition(subtitlePositionX, fallback: 0.5)
        settings.subtitlePositionY = Self.clampSubtitlePosition(subtitlePositionY, fallback: 0.12)
        settings.lastUsedSpeed = Self.normalizeSpeed(speed)
        settings.appLanguage = appLanguage
        settings.numericKeySpeeds = Self.normalizeNumericKeySpeeds(numericKeySpeeds)
        if let frame = attachedWindow {
            settings.lastWindowFrame = NSStringFromRect(frame.frame)
        }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        Self.settingsCache = settings
        Self.writeJSONAtomically(data, to: Self.settingsURL)
        NotificationCenter.default.post(name: Self.preferencesDidChangeNotification, object: self)
    }

    private static var fileSettingsCache: [String: FileSettings]?

    private static func loadFileSettings() -> [String: FileSettings] {
        if let cached = fileSettingsCache {
            return cached
        }
        guard let data = try? Data(contentsOf: fileSettingsURL),
              let dict = try? JSONDecoder().decode([String: FileSettings].self, from: data) else {
            let empty: [String: FileSettings] = [:]
            fileSettingsCache = empty
            return empty
        }
        fileSettingsCache = dict
        return dict
    }

    private static func saveFileSettings(_ dict: [String: FileSettings]) {
        fileSettingsCache = dict
        guard let data = try? JSONEncoder().encode(dict) else { return }
        writeJSONAtomically(data, to: fileSettingsURL)
    }

    private static func loadURLSet(from url: URL) -> Set<URL> {
        guard let data = try? Data(contentsOf: url),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths.map { URL(fileURLWithPath: $0) })
    }

    private static func saveURLSet(_ set: Set<URL>, to url: URL) {
        let paths = set.map { $0.path }
        guard let data = try? JSONEncoder().encode(paths) else { return }
        writeJSONAtomically(data, to: url)
    }

    private func saveOpenedFiles() {
        Self.saveURLSet(openedFiles, to: Self.openedFilesURL)
    }

    private func saveCompletedFiles() {
        Self.saveURLSet(completedFiles, to: Self.completedFilesURL)
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

    private func removeFileSettings(for url: URL) {
        var dict = Self.loadFileSettings()
        guard dict.removeValue(forKey: url.path) != nil else { return }
        Self.saveFileSettings(dict)
    }

    deinit {
        mediaAnalysisTask?.cancel()
        pendingVolumeSaveTask?.cancel()
        pendingVLCSeekTask?.cancel()
        pendingSpeedSaveTask?.cancel()
        pendingWindowFrameSaveTask?.cancel()
        playbackFailureTimer?.invalidate()
        toastHideWorkItem?.cancel()
        for observer in windowFrameObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let nativeEndObserver {
            NotificationCenter.default.removeObserver(nativeEndObserver)
        }
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
        let normalizedURLs = urls
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let firstURL = normalizedURLs.first else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: firstURL.path, isDirectory: &isDirectory)

        if normalizedURLs.count == 1, isDirectory.boolValue {
            loadPlaylist(with: firstURL)
            if let firstFile = playlist.first {
                openFromPlaylist(firstFile)
            }
            return
        }

        if normalizedURLs.count == 1 {
            loadPlaylist(with: firstURL)
            openFromPlaylist(firstURL)
            return
        }

        let fileURLs = normalizedURLs.filter { url in
            var directory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            return !directory.boolValue
        }
        guard !fileURLs.isEmpty else { return }
        var seen = Set<URL>()
        playlist = fileURLs.filter { seen.insert($0).inserted }
        currentIndex = 0
        openFromPlaylist(playlist[0])
    }

    func openBenchmarkMedia(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        loadPlaylist(with: url)
        loopMode = .singleFile
        openFromPlaylist(url, forceStartAtBeginning: true)
    }

    func setBenchmarkSpeed(_ value: Double) {
        speed = Self.normalizeSpeed(value)
        switch playbackBackend {
        case .native:
            applyNativePlaybackSpeed()
        case .vlc:
            vlcPlayer.setSpeed(speed)
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
            isPaused = false
            resumeNativePlaybackAtCurrentTime()
        case .vlc:
            vlcPlayer.play()
            isPaused = false
        }
    }

    func pause() {
        switch playbackBackend {
        case .native:
            invalidateNativePlaybackRefresh()
            nativePlayer.pause()
        case .vlc:
            vlcPlayer.pause()
        }
        isPaused = true
        saveCurrentProgress(force: true)
    }

    func prepareForWindowClose() {
        flushPendingVolumeSave()
        flushPendingSpeedSave()
        flushPendingWindowFrameSave()
        closeCurrentPlaybackFile(showToast: false)
    }

    func closeCurrentFile() {
        closeCurrentPlaybackFile(showToast: true)
    }

    func deleteCurrentFileAndTrash() {
        guard let url = currentFileURL else { return }
        
        // 1. Determine the next file to play in the playlist
        var nextURL: URL? = nil
        if playlist.count > 1 {
            if let idx = playlist.firstIndex(of: url) {
                if idx + 1 < playlist.count {
                    nextURL = playlist[idx + 1]
                } else if idx - 1 >= 0 {
                    nextURL = playlist[idx - 1]
                }
            }
        }
        
        // 2. Stop playback and close the current file to release file locks
        closeCurrentPlaybackFile(showToast: false)
        
        // 3. Move the file to trash
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let idx = playlist.firstIndex(of: url) {
                playlist.remove(at: idx)
            }
            if let next = nextURL, let newIdx = playlist.firstIndex(of: next) {
                currentIndex = newIdx
            } else {
                currentIndex = -1
            }
            recentFiles.removeAll { $0 == url.path }
            Self.saveRecentFilesToDisk(recentFiles)
            openedFiles.remove(url)
            saveOpenedFiles()
            completedFiles.remove(url)
            saveCompletedFiles()
            removeFileSettings(for: url)
            selectedPlaylistIndices.removeAll()
            playlistDurations.removeValue(forKey: url)
            BZLogger.info("Moved file to trash: \(url.path)")
            showToastMessage(t("已将文件移入废纸篓"))
        } catch {
            BZLogger.error("Failed to move file to trash: \(error.localizedDescription)")
            currentIndex = playlist.firstIndex(of: url) ?? -1
            openFromPlaylist(url)
            showToastMessage(t("无法将文件移入废纸篓"))
            return
        }
        
        // 4. Play the next file if available
        if let next = nextURL {
            openFromPlaylist(next)
        } else {
            attachedWindow?.close()
        }
    }

    func copyFileToClipboard(url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        showToastMessage(t("已复制文件路径"), isSuccess: true)
    }

    func copyCurrentOrSelectedFilesToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        if !selectedPlaylistIndices.isEmpty {
            let urls = selectedPlaylistIndices.sorted().compactMap { idx -> NSURL? in
                guard idx < playlist.count else { return nil }
                return playlist[idx] as NSURL
            }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls)
                showToastMessage(t("已复制文件路径"), isSuccess: true)
                return
            }
        }
        
        if let currentURL = currentFileURL {
            pasteboard.writeObjects([currentURL as NSURL])
            showToastMessage(t("已复制文件路径"), isSuccess: true)
        }
    }

    private func closeCurrentPlaybackFile(showToast: Bool) {
        flushPendingVolumeSave()
        flushPendingSpeedSave()
        flushPendingWindowFrameSave()
        mediaAnalysisTask?.cancel()
        invalidatePendingSeek()
        startNewPlaybackGeneration()
        saveCurrentProgress(force: true)
        switch playbackBackend {
        case .native:
            unbindNativePlayer()
            nativePlayer.pause()
            nativePlayer.replaceCurrentItem(with: nil)
        case .vlc:
            vlcPlayer.stop()
        }
        currentFileURL = nil
        currentMediaHasAV1Video = false
        openedFilePath = ""
        currentTime = 0
        duration = 0
        isPaused = true
        isSeeking = false
        currentIndex = -1
        selectedSubtitlePath = nil
        clearNativeSubtitleOverlay()
        windowTitle = Self.defaultWindowTitle
        attachedWindow?.title = windowTitle
        playbackError = nil
        attemptedBackendSwitch = false
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil
        subtitleCleanupTracker.clean()
        if showToast {
            showToastMessage(t("已关闭当前文件"))
        }
    }

    func togglePause() {
        isPaused ? play() : pause()
    }

    func setVolume(_ newVolume: Double) {
        guard newVolume.isFinite else { return }
        volume = Self.normalizeVolume(newVolume)
        applyVolumeToActiveBackend()
        if volume > 0, isMuted {
            isMuted = false
            applyMuteToActiveBackend()
        }
        scheduleVolumeSave()
    }

    func toggleMute() {
        isMuted.toggle()
        applyMuteToActiveBackend()
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
        BZLogger.debug("Manually navigating to previous file")
        moveInPlaylist(step: -1)
    }
    
    func nextFile() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - Self.globalLastNavigationTime > 1.0 else { return }
        Self.globalLastNavigationTime = now
        BZLogger.debug("Manually navigating to next file")
        moveInPlaylist(step: 1)
    }

    func seek(to progress: Double) {
        guard duration > 0, progress.isFinite else { return }
        let targetTime = duration * progress
        let time = CMTime(seconds: targetTime, preferredTimescale: 600)
        let seekGeneration = UUID()
        activeSeekGeneration = seekGeneration
        isSeeking = true
        currentTime = targetTime
        updateNativeSubtitleOverlay(at: targetTime)
        if playbackBackend == .native {
            pendingVLCSeekTask?.cancel()
            pendingVLCSeekTask = nil
            nativePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.activeSeekGeneration == seekGeneration else { return }
                    self.isSeeking = false
                    self.updateNativeSubtitleOverlay(at: self.currentTime)
                }
            }
        } else {
            scheduleVLCSeek(to: targetTime, seekGeneration: seekGeneration)
        }
    }

    func setSpeed(_ value: Double) {
        speed = Self.normalizeSpeed(value)
        scheduleSpeedSave(for: currentFileURL)

        switch playbackBackend {
        case .native:
            applyNativePlaybackSpeed()
        case .vlc:
            vlcPlayer.setSpeed(speed)
        }
    }

    func setSpeedWithToast(_ value: Double) {
        setSpeed(value)
        showToastMessage(String(format: t("速度: %.2fx"), speed))
    }

    func numericKeySpeed(for digit: Int) -> Double {
        guard let index = Self.numericSpeedDigits.firstIndex(of: digit),
              numericKeySpeeds.indices.contains(index) else {
            return Double(digit)
        }
        return numericKeySpeeds[index]
    }

    func setNumericKeySpeed(_ value: Double, for digit: Int) {
        guard let index = Self.numericSpeedDigits.firstIndex(of: digit) else { return }
        var speeds = Self.normalizeNumericKeySpeeds(numericKeySpeeds)
        speeds[index] = Self.normalizeSpeed(value)
        numericKeySpeeds = speeds
        saveSettings()
    }

    func setSpeedForNumericKey(_ digit: Int) {
        setSpeedWithToast(numericKeySpeed(for: digit))
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
        showToastMessage(String(format: t("速度: %.2fx"), speed))
    }

    func toggleSpeed() {
        let currentSpeed = speed
        setSpeed(memorySpeed)
        memorySpeed = currentSpeed
        // 显示 Toast 提示
        showToastMessage(String(format: t("速度: %.2fx"), speed))
    }

    func setShortcutSeekSeconds(_ value: Double) {
        let normalized = value.isFinite ? max(value, 0.1) : 0.1
        shortcutSeekSeconds = normalized
        saveSettings()
    }

    func setShortcutFrameStepCount(_ value: Int) {
        let normalized = max(value, 1)
        shortcutFrameStepCount = normalized
        saveSettings()
    }

    func setPreviousFileKeyCode(_ value: UInt16) {
        previousFileKeyCode = Self.normalizeUserShortcutKeyCode(Int(value), fallback: 33)
        saveSettings()
    }

    func setNextFileKeyCode(_ value: UInt16) {
        nextFileKeyCode = Self.normalizeUserShortcutKeyCode(Int(value), fallback: 30)
        saveSettings()
    }

    func setAudioStepDownKeyCode(_ value: UInt16) {
        audioStepDownKeyCode = Self.normalizeUserShortcutKeyCode(Int(value), fallback: 43)
        saveSettings()
    }

    func setAudioStepUpKeyCode(_ value: UInt16) {
        audioStepUpKeyCode = Self.normalizeUserShortcutKeyCode(Int(value), fallback: 47)
        saveSettings()
    }

    func setSpeedToggleKeyCode(_ value: UInt16) {
        speedToggleKeyCode = Self.normalizeUserShortcutKeyCode(Int(value), fallback: 24)
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

    func setAudioOnlyWhenMinimized(_ value: Bool) {
        audioOnlyWhenMinimized = value
        saveSettings()
        if !value, isAudioOnlyMode {
            exitAudioOnlyMode()
        }
    }

    func enterAudioOnlyModeIfNeeded() {
        enterAudioOnlyMode(force: false)
    }

    func enterAudioOnlyModeForBenchmark() {
        enterAudioOnlyMode(force: true)
    }

    private func enterAudioOnlyMode(force: Bool) {
        guard (force || audioOnlyWhenMinimized),
              !isAudioOnlyMode,
              let url = currentFileURL else { return }

        let nativeVideoTracks: [(AVPlayerItemTrack, Bool)]
        let audioTrack: Int32?
        let subtitleTrack: Int32?
        switch playbackBackend {
        case .native:
            nativeVideoTracks = nativePlayer.currentItem?.tracks.compactMap { track in
                guard track.assetTrack?.mediaType == .video else { return nil }
                return (track, track.isEnabled)
            } ?? []
            audioTrack = nil
            subtitleTrack = nil
        case .vlc:
            nativeVideoTracks = []
            audioTrack = vlcPlayer.currentAudioIndex
            subtitleTrack = vlcPlayer.currentSubtitleIndex
        }

        audioOnlyState = AudioOnlyState(
            url: url,
            backend: playbackBackend,
            time: max(currentTime, 0),
            isPaused: isPaused,
            speed: speed,
            audioTrack: audioTrack,
            subtitleTrack: subtitleTrack,
            nativeVideoTracks: nativeVideoTracks
        )
        isAudioOnlyMode = true

        switch playbackBackend {
        case .native:
            for (track, _) in nativeVideoTracks {
                track.isEnabled = false
            }
        case .vlc:
            pendingAudioOnlyAudioTrack = audioTrack
            pendingAudioOnlySubtitleTrack = subtitleTrack
            loadVLC(url: url, resumeAt: currentTime, startPaused: isPaused)
        }
    }

    func exitAudioOnlyMode() {
        guard let state = audioOnlyState else { return }
        audioOnlyState = nil
        isAudioOnlyMode = false

        switch state.backend {
        case .native:
            for (track, enabled) in state.nativeVideoTracks {
                track.isEnabled = enabled
            }
        case .vlc:
            pendingAudioOnlyAudioTrack = state.audioTrack
            pendingAudioOnlySubtitleTrack = state.subtitleTrack
            loadVLC(url: state.url, resumeAt: state.time, startPaused: state.isPaused)
            setSpeed(state.speed)
        }
    }

    private func clearAudioOnlyModeForMediaChange() {
        guard let state = audioOnlyState else { return }
        audioOnlyState = nil
        isAudioOnlyMode = false
        pendingAudioOnlyAudioTrack = nil
        pendingAudioOnlySubtitleTrack = nil
        if state.backend == .native {
            for (track, enabled) in state.nativeVideoTracks {
                track.isEnabled = enabled
            }
        }
    }

    func setSubtitleBackgroundOpacity(_ value: Int) {
        let normalized = Self.clampSubtitleOpacity(value)
        subtitleBackgroundOpacity = normalized
        saveSettings()
        // VLC applies opacity via media options (requires reload).
        // Native overlay reads @Published opacity directly.
        reloadVLCMediaIfNeeded()
    }

    func setSubtitleFontSize(_ size: Int) {
        subtitleFontSize = max(1, size)
        saveSettings()
        // VLC applies font size via media options (requires reload).
        // Native overlay reads @Published font size directly.
        reloadVLCMediaIfNeeded()
    }

    /// Persist native subtitle bubble center (fractions of host size).
    /// X: 0=left … 1=right. Y: 0=bottom … 1=top.
    func setSubtitlePosition(x: Double, y: Double, persist: Bool = true) {
        let nx = Self.clampSubtitlePosition(x, fallback: subtitlePositionX)
        let ny = Self.clampSubtitlePosition(y, fallback: subtitlePositionY)
        let changed = abs(nx - subtitlePositionX) > 0.0005 || abs(ny - subtitlePositionY) > 0.0005
        guard changed else { return }
        subtitlePositionX = nx
        subtitlePositionY = ny
        nativeSubtitleRenderID &+= 1
        if persist {
            saveSettings()
        }
    }

    func resetSubtitlePosition() {
        setSubtitlePosition(x: 0.5, y: 0.12, persist: true)
        showToastMessage(t("字幕位置已重置"))
    }

    /// Point size used by the native subtitle overlay (maps VLC relative size to pt).
    var nativeSubtitlePointSize: CGFloat {
        // VLC freetype-rel-fontsize defaults around 55; map to a readable macOS point size.
        // Keep this fairly large so external subtitles remain obvious on high-DPI displays.
        let mapped = CGFloat(subtitleFontSize) * 0.55
        return min(max(mapped, 18), 72)
    }

    func setAudioDelayStepMs(_ value: Double) {
        let normalized = Self.normalizeAudioDelayStep(value)
        audioDelayStepMs = normalized
        saveSettings()
    }

    func setAppLanguage(_ lang: String) {
        appLanguage = lang
        saveSettings()
        updateWindowTitle(currentFileURL?.lastPathComponent ?? "")
    }

    func t(_ key: String) -> String {
        return Localization.translate(key, for: getActiveLanguage())
    }

    func getActiveLanguage() -> String {
        let lang = appLanguage
        if lang == "auto" {
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            if preferred.hasPrefix("zh") { return "zh" }
            if preferred.hasPrefix("ja") { return "ja" }
            if preferred.hasPrefix("de") { return "de" }
            if preferred.hasPrefix("fr") { return "fr" }
            if preferred.hasPrefix("es") { return "es" }
            if preferred.hasPrefix("ru") { return "ru" }
            return "en"
        }
        return lang
    }

    func languageKeywords(for langCode: String) -> [String] {
        switch langCode {
        case "zh":
            return ["中文", "cn", "zh", "chi", "simplified", "traditional", "简", "繁"]
        case "en":
            return ["en", "eng", "english"]
        case "ja":
            return ["ja", "jp", "japanese", "日", "日文"]
        case "de":
            return ["de", "ger", "deutsch", "german", "德", "德文"]
        case "fr":
            return ["fr", "fre", "fra", "french", "法", "法文"]
        case "es":
            return ["es", "spa", "spanish", "西班牙", "西班牙文", "西"]
        case "ru":
            return ["ru", "rus", "russian", "俄", "俄文"]
        default:
            return []
        }
    }

    func subtitlePriority(for url: URL, mediaURL: URL, activeLanguage: String) -> Int {
        let mediaBase = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        
        if stem == mediaBase {
            return 2 // Exact match
        }
        
        if stem.hasPrefix(mediaBase) {
            let extra = String(stem.dropFirst(mediaBase.count))
            let keywords = languageKeywords(for: activeLanguage)
            for keyword in keywords {
                if extra.contains(keyword.lowercased()) {
                    return 1 // Language match (highest priority)
                }
            }
        }
        
        return 3 // Other match
    }

    func sortSubtitles(_ candidates: [URL], for mediaURL: URL, activeLanguage: String) -> [URL] {
        let extPriority: [String: Int] = [
            "srt": 0,
            "ass": 1,
            "ssa": 2,
            "vtt": 3,
            "sub": 4,
            "idx": 5
        ]
        
        return candidates.sorted { left, right in
            let leftPrio = subtitlePriority(for: left, mediaURL: mediaURL, activeLanguage: activeLanguage)
            let rightPrio = subtitlePriority(for: right, mediaURL: mediaURL, activeLanguage: activeLanguage)
            if leftPrio != rightPrio {
                return leftPrio < rightPrio // 1 < 2 < 3
            }
            
            let leftExt = left.pathExtension.lowercased()
            let rightExt = right.pathExtension.lowercased()
            let leftExtOrder = extPriority[leftExt] ?? Int.max
            let rightExtOrder = extPriority[rightExt] ?? Int.max
            if leftExtOrder != rightExtOrder {
                return leftExtOrder < rightExtOrder
            }
            
            return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
        }
    }

    func subtitleMenuEntries() -> [SubtitleMenuEntry] {
        let available = discoverSubtitleFilesForCurrentMedia()
        let sorted = sortSubtitles(available, for: currentFileURL ?? URL(fileURLWithPath: ""), activeLanguage: getActiveLanguage())
        var entries: [SubtitleMenuEntry] = [
            SubtitleMenuEntry(title: t("关闭字幕"), path: nil, isSelected: selectedSubtitlePath == nil)
        ]

        entries.append(contentsOf: sorted.map { url in
            SubtitleMenuEntry(
                title: url.lastPathComponent,
                path: url.path,
                isSelected: selectedSubtitlePath == url.path
            )
        })
        return entries
    }

    func selectSubtitle(path: String?) {
        selectedSubtitlePath = path
        if path == nil {
            clearNativeSubtitleOverlay()
            if playbackBackend == .vlc {
                vlcPlayer.disableSubtitle()
            }
            showToastMessage(t("字幕：已关闭"))
            return
        }

        guard let path else { return }

        // Native backend (including AV1-forced native): render external subtitles with overlay.
        // Do not switch to VLC just for external subtitles — AV1 cannot use VLC, and native overlay works for common text formats.
        if playbackBackend == .native {
            if applyNativeExternalSubtitle(path: path) {
                showToastMessage(t("字幕：") + (path as NSString).lastPathComponent)
            } else {
                showToastMessage(t("无法加载字幕文件"))
            }
            return
        }

        if playbackBackend == .vlc {
            let subtitleURL = URL(fileURLWithPath: path)
            if let utf8SubtitleURL = convertSubtitleToUTF8(at: subtitleURL) {
                vlcPlayer.setExternalSubtitle(url: utf8SubtitleURL)
            } else {
                vlcPlayer.setExternalSubtitle(url: subtitleURL)
            }
            clearNativeSubtitleOverlay()
        }
        showToastMessage(t("字幕：") + (path as NSString).lastPathComponent)
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
        writeJSONAtomically(data, to: url)
    }

    private static func writeJSONAtomically(_ data: Data, to url: URL) {
        JSONWriteQueue.shared.enqueue(data, to: url)
    }

    func adjustAudioDelay(by deltaMs: Double) {
        guard deltaMs.isFinite else { return }
        let newDelay = audioDelayMs + deltaMs
        guard newDelay.isFinite else { return }
        audioDelayMs = Self.normalizeAudioDelay(newDelay)
        saveSettings()
        if let url = currentFileURL {
            var fileSettings = loadFileSettings(for: url)
            fileSettings.audioDelayMs = audioDelayMs
            saveFileSettings(for: url, fileSettings)
        }
        applyAudioDelay()
        showToastMessage(String(format: t("音频延迟: %.0f ms"), audioDelayMs))
    }

    func resetAudioDelay() {
        audioDelayMs = 0
        saveSettings()
        if let url = currentFileURL {
            var fileSettings = loadFileSettings(for: url)
            fileSettings.audioDelayMs = 0
            saveFileSettings(for: url, fileSettings)
        }
        applyAudioDelay()
        showToastMessage(t("音频延迟: 已重置"))
    }

    func applyAudioDelay() {
        guard let url = currentFileURL else { return }
        let resumeAt = currentTime > 0 && currentTime < duration ? currentTime : nil
        let wasPaused = isPaused

        if audioDelayMs != 0, playbackBackend == .native {
            if currentMediaHasAV1Video {
                showToastMessage(t("AV1 视频当前不支持音频延迟，以避免切换到不稳定的 VLC 解码器"))
                return
            }
            let generation = startNewPlaybackGeneration()
            selectBackend(.vlc)
            loadVLC(url: url, resumeAt: resumeAt, startPaused: wasPaused)
            schedulePlaybackFailureCheck(
                for: url,
                backend: .vlc,
                resumeAt: resumeAt,
                generation: generation
            )
        } else if playbackBackend == .vlc {
            vlcPlayer.setAudioDelay(audioDelayMs)
        }
    }

    func refreshPreferences() {
        let settings = Self.loadSettings()
        shortcutSeekSeconds = max(settings.shortcutSeekSeconds, 0.1)
        shortcutFrameStepCount = max(settings.shortcutFrameStepCount, 1)
        previousFileKeyCode = Self.normalizeUserShortcutKeyCode(settings.previousFileKeyCode, fallback: 33)
        nextFileKeyCode = Self.normalizeUserShortcutKeyCode(settings.nextFileKeyCode, fallback: 30)
        audioStepDownKeyCode = Self.normalizeUserShortcutKeyCode(settings.audioStepDownKeyCode, fallback: 43)
        audioStepUpKeyCode = Self.normalizeUserShortcutKeyCode(settings.audioStepUpKeyCode, fallback: 47)
        speedToggleKeyCode = Self.normalizeUserShortcutKeyCode(settings.speedToggleKeyCode, fallback: 24)
        numericKeySpeeds = Self.normalizeNumericKeySpeeds(settings.numericKeySpeeds ?? [])
        playlistOrder = PlaylistOrder(rawValue: settings.playlistOrder) ?? playlistOrder
        loopMode = LoopMode(rawValue: settings.loopMode) ?? loopMode
        windowOpenBehavior = WindowOpenBehavior(rawValue: settings.windowOpenBehavior) ?? windowOpenBehavior
        let normalizedVolume = Self.normalizeVolume(settings.volume)
        volume = normalizedVolume
        isMuted = settings.isMuted
        allowMultipleWindows = settings.allowMultipleWindows
        audioDelayStepMs = Self.normalizeAudioDelayStep(settings.audioDelayStepMs)
        showRecentFiles = settings.showRecentFiles
        audioOnlyWhenMinimized = settings.audioOnlyWhenMinimized
        subtitleBackgroundOpacity = Self.clampSubtitleOpacity(settings.subtitleBackgroundOpacity)
        subtitleFontSize = max(settings.subtitleFontSize, 1)
        subtitlePositionX = Self.clampSubtitlePosition(settings.subtitlePositionX, fallback: 0.5)
        subtitlePositionY = Self.clampSubtitlePosition(settings.subtitlePositionY, fallback: 0.12)
        appLanguage = settings.appLanguage ?? "auto"
        if currentFileURL == nil {
            audioDelayMs = Self.normalizeAudioDelay(settings.audioDelayMs)
            speed = Self.normalizeSpeed(settings.lastUsedSpeed)
        }
        applyVolumeToActiveBackend()
        applyMuteToActiveBackend()
        if fileAssociationStatus == "未执行格式关联" || fileAssociationStatus == "Formats not associated" || fileAssociationStatus == Localization.translate("未执行格式关联", for: "en") {
            fileAssociationStatus = t("未执行格式关联")
        }
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
        guard !isAudioOnlyMode else {
            showToastMessage(t("最小化音频模式下不能切换播放后端"))
            return
        }
        // Audio delay still requires VLC; external subtitles are supported on native via overlay.
        if playbackBackend == .vlc && audioDelayMs != 0 {
            showToastMessage(t("当前音频延迟需要使用 VLC 播放后端"))
            return
        }
        let resumeAt = currentTime > 0 && currentTime < duration ? currentTime : nil
        let wasPaused = isPaused
        let newBackend: PlaybackBackend = playbackBackend == .native ? .vlc : .native
        if newBackend == .vlc, currentMediaHasAV1Video {
            showToastMessage(t("AV1 视频已禁用 VLC 后端，以避免解码器崩溃"))
            return
        }
        let generation = startNewPlaybackGeneration()
        selectBackend(newBackend)

        switch newBackend {
        case .native:
            openWithNative(url: url, resumeAt: resumeAt, startPaused: wasPaused)
            // Restore external subtitle overlay after switching back to native.
            if let selectedSubtitlePath {
                _ = applyNativeExternalSubtitle(path: selectedSubtitlePath)
            }
        case .vlc:
            clearNativeSubtitleOverlay()
            loadVLC(url: url, resumeAt: resumeAt, startPaused: wasPaused)
        }
        schedulePlaybackFailureCheck(
            for: url,
            backend: newBackend,
            resumeAt: resumeAt,
            generation: generation
        )
    }

    func seekBy(seconds delta: Double) {
        guard hasOpenedFile else { return }
        guard delta.isFinite else { return }
        let baseTime = currentTime.isFinite ? currentTime : 0
        let upperBound = duration > 0 ? duration : Double(Int32.max) / 1_000
        let rawTarget = baseTime + delta
        guard rawTarget.isFinite else { return }
        let target = max(0, min(upperBound, rawTarget))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        let seekGeneration = UUID()
        activeSeekGeneration = seekGeneration
        isSeeking = true
        if playbackBackend == .native {
            pendingVLCSeekTask?.cancel()
            pendingVLCSeekTask = nil
            nativePlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.activeSeekGeneration == seekGeneration else { return }
                    self.isSeeking = false
                    self.updateNativeSubtitleOverlay(at: self.currentTime)
                }
            }
        } else {
            scheduleVLCSeek(to: target, seekGeneration: seekGeneration)
        }
        currentTime = target
        updateNativeSubtitleOverlay(at: target)
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
            guard self.currentFileURL == url else { return }
            self.onShowFileInfo?(text)
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
                fileAssociationStatus = t("关联失败：系统拒绝更新 LaunchServices。")
                return
            }
        }

        let initialVerification = verifyAssociations(typeMappings: typeMappings, bundleID: bundleID as String)
        if initialVerification.failed.isEmpty {
            fileAssociationStatus = String(format: t("已注册并关联：%@"), initialVerification.associated.joined(separator: ", "))
            return
        }

        fileAssociationStatus = String(format: t("关联失败：%@；请确认程序位于 /Applications/BZPlayer.app"), initialVerification.failed.joined(separator: ", "))
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

    private func bindVLCCallbacks() {
        vlcPlayer.onTimeChanged = { [weak self] time in
            guard let self, self.playbackBackend == .vlc else { return }
            self.currentTime = time.isFinite ? time : 0
            self.saveCurrentProgressIfNeeded()
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
            self.selectDefaultTracksBySystemLanguage()
            if let audioTrack = self.pendingAudioOnlyAudioTrack {
                self.vlcPlayer.currentAudioIndex = audioTrack
                self.pendingAudioOnlyAudioTrack = nil
            }
            if let subtitleTrack = self.pendingAudioOnlySubtitleTrack {
                self.vlcPlayer.currentSubtitleIndex = subtitleTrack
                self.pendingAudioOnlySubtitleTrack = nil
            }
            if let selectedSubtitlePath = self.selectedSubtitlePath {
                self.selectSubtitle(path: selectedSubtitlePath)
            }
        }
        vlcPlayer.onStatusChanged = { [weak self] status in
            guard let self, self.playbackBackend == .vlc else { return }
            self.playbackEngineStatus = status
        }
        vlcPlayer.onEndReached = { [weak self] in
            guard let self, self.playbackBackend == .vlc, self.currentFileURL != nil else { return }
            self.handlePlaybackFinished()
        }
    }

    private func bindNativePlayer(for player: AVPlayer, generation: UUID) {
        nativeTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      self.nativePlayer === player,
                      self.playbackBackend == .native,
                      self.mediaOpenGeneration == generation else { return }
                let seconds = time.seconds
                
                // Stall detection: if playing but time isn't moving
                if !self.isPaused && !self.isSeeking && !self.nativePlaybackRefreshInFlight && seconds.isFinite && seconds > 0 {
                    if seconds == self.lastStallPosition {
                        self.nativeStallCount += 1
                        if self.nativeStallCount > 30 { // ~3 seconds stall
                            self.nativeStallCount = 0
                            BZLogger.error("Native player stalled at \(seconds)s; switching to VLC")
                            if let url = self.currentFileURL {
                                let resumeAt = seconds.isFinite ? seconds : nil
                                if self.currentMediaHasAV1Video {
                                    self.reportAV1PlaybackFailure(for: url)
                                    return
                                }
                                let generation = self.startNewPlaybackGeneration()
                                self.selectBackend(.vlc)
                                self.loadVLC(url: url, resumeAt: resumeAt)
                                self.schedulePlaybackFailureCheck(
                                    for: url,
                                    backend: .vlc,
                                    resumeAt: resumeAt,
                                    generation: generation
                                )
                                return
                            }
                        }
                    } else {
                        self.nativeStallCount = 0
                        self.lastStallPosition = seconds
                    }
                } else {
                    self.nativeStallCount = 0
                }

                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                self.updateNativeSubtitleOverlay(at: self.currentTime)
                self.saveCurrentProgressIfNeeded()
            }
        }

        if let observer = nativeEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        nativeEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self, weak player] notification in
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      self.nativePlayer === player,
                      self.playbackBackend == .native,
                      self.mediaOpenGeneration == generation else { return }
                let notificationItem = notification.object as? AVPlayerItem
                let currentItem = self.nativePlayer.currentItem
                guard let notificationItem, notificationItem === currentItem else { return }
                self.handlePlaybackFinished()
            }
        }
    }

    private func unbindNativePlayer() {
        if let nativeTimeObserver {
            nativePlayer.removeTimeObserver(nativeTimeObserver)
            self.nativeTimeObserver = nil
        }
        if let nativeEndObserver {
            NotificationCenter.default.removeObserver(nativeEndObserver)
            self.nativeEndObserver = nil
        }
        nativeItemStatusObserver = nil
    }

    private func selectBackend(_ backend: PlaybackBackend) {
        guard playbackInfrastructureInitialized else {
            playbackBackend = backend
            return
        }
        invalidatePendingSeek()
        let previousBackend = playbackBackend
        playbackBackend = backend
        invalidateNativePlaybackRefresh()

        if previousBackend == .native {
            unbindNativePlayer()
            nativePlayer.pause()
            nativePlayer.replaceCurrentItem(with: nil)
        }

        if previousBackend == .vlc {
            vlcPlayer.detach()
            vlcPlayer.stop()
            vlcPlayer.cancelPendingRender()
        }

        switch backend {
        case .native:
            playbackEngineStatus = "AVPlayer"
            syncText = "播放链路：系统原生"
            nativePlayer.volume = Float(volume / 100.0)
            nativePlayer.isMuted = isMuted
        case .vlc:
            // VLC renders its own subtitles; hide the native text overlay.
            clearNativeSubtitleOverlay()
            playbackEngineStatus = "VLC/libvlc"
            syncText = "播放链路：VLC/libvlc"
            vlcPlayer.setVolume(volume)
            vlcPlayer.setMuted(isMuted)
            vlcPlayer.setAudioDelay(audioDelayMs)
        }
    }

    private func applyVolumeToActiveBackend() {
        guard playbackInfrastructureInitialized else { return }
        switch playbackBackend {
        case .native:
            nativePlayer.volume = Float(volume / 100.0)
        case .vlc:
            vlcPlayer.setVolume(volume)
        }
    }

    private func applyMuteToActiveBackend() {
        guard playbackInfrastructureInitialized else { return }
        switch playbackBackend {
        case .native:
            nativePlayer.isMuted = isMuted
        case .vlc:
            vlcPlayer.setMuted(isMuted)
        }
    }

    private func scheduleVolumeSave() {
        pendingVolumeSaveTask?.cancel()
        pendingVolumeSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingVolumeSaveTask = nil
            self.saveSettings()
        }
    }

    private func flushPendingVolumeSave() {
        guard pendingVolumeSaveTask != nil else { return }
        pendingVolumeSaveTask?.cancel()
        pendingVolumeSaveTask = nil
        saveSettings()
    }

    private func scheduleVLCSeek(to seconds: Double, seekGeneration: UUID) {
        guard seconds.isFinite, seconds >= 0 else { return }
        pendingVLCSeekTask?.cancel()
        let mediaGeneration = mediaOpenGeneration
        pendingVLCSeekTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.playbackBackend == .vlc,
                  self.mediaOpenGeneration == mediaGeneration,
                  self.activeSeekGeneration == seekGeneration else { return }
            self.vlcPlayer.seek(seconds: seconds)
            self.pendingVLCSeekTask = nil
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.playbackBackend == .vlc,
                  self.mediaOpenGeneration == mediaGeneration,
                  self.activeSeekGeneration == seekGeneration else { return }
            self.isSeeking = false
        }
    }

    private func invalidatePendingSeek() {
        pendingVLCSeekTask?.cancel()
        pendingVLCSeekTask = nil
        activeSeekGeneration = UUID()
        isSeeking = false
    }

    private func invalidateNativePlaybackRefresh() {
        nativePlaybackRefreshGeneration = UUID()
        nativePlaybackRefreshInFlight = false
    }

    private func applyNativePlaybackSpeed() {
        guard playbackBackend == .native else { return }

        if isPaused {
            invalidateNativePlaybackRefresh()
            nativePlayer.pause()
            nativePlayer.rate = 0
            return
        }

        resumeNativePlaybackAtCurrentTime()
    }

    /// Re-prime AVPlayer at the current frame when the rate changes.
    ///
    /// AVPlayer can keep advancing audio while its video renderer is no
    /// longer synchronized after a live rate change. A zero-tolerance seek
    /// followed by playImmediately(atRate:) is the same refresh path that
    /// makes pause/resume recover the video, but it is now applied directly
    /// when changing speed. The generation prevents an old seek completion
    /// from restarting playback after a newer speed change, pause, or media
    /// switch.
    private func resumeNativePlaybackAtCurrentTime() {
        guard playbackBackend == .native, !isPaused else { return }

        let player = nativePlayer
        let targetRate = Float(speed)
        guard targetRate.isFinite, targetRate > 0 else { return }

        invalidateNativePlaybackRefresh()
        let refreshGeneration = nativePlaybackRefreshGeneration
        let mediaGeneration = mediaOpenGeneration
        nativePlaybackRefreshInFlight = true

        let currentTime = player.currentTime()
        guard currentTime.isValid, currentTime.isNumeric else {
            nativePlaybackRefreshInFlight = false
            player.playImmediately(atRate: targetRate)
            return
        }

        player.pause()
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor [weak self, weak player] in
                guard let self,
                      let player,
                      player === self.nativePlayer,
                      self.playbackBackend == .native,
                      self.mediaOpenGeneration == mediaGeneration,
                      self.nativePlaybackRefreshGeneration == refreshGeneration else { return }

                self.nativePlaybackRefreshInFlight = false
                guard finished, !self.isPaused else { return }
                player.playImmediately(atRate: Float(self.speed))
            }
        }
    }

    @discardableResult
    private func startNewPlaybackGeneration() -> UUID {
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil
        invalidateNativePlaybackRefresh()
        let generation = UUID()
        mediaOpenGeneration = generation
        return generation
    }

    private func scheduleSpeedSave(for url: URL?) {
        pendingSpeedSaveTask?.cancel()
        pendingSpeedSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingSpeedSaveTask = nil
            if let url, self.currentFileURL == url {
                self.saveSpeedForFile(url)
            }
            self.saveSettings()
        }
    }

    private func flushPendingSpeedSave() {
        guard pendingSpeedSaveTask != nil else { return }
        pendingSpeedSaveTask?.cancel()
        pendingSpeedSaveTask = nil
        if let url = currentFileURL {
            saveSpeedForFile(url)
        }
        saveSettings()
    }

    private func scheduleWindowFrameSave() {
        pendingWindowFrameSaveTask?.cancel()
        pendingWindowFrameSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingWindowFrameSaveTask = nil
            self.saveSettings()
        }
    }

    private func flushPendingWindowFrameSave() {
        guard pendingWindowFrameSaveTask != nil else { return }
        pendingWindowFrameSaveTask?.cancel()
        pendingWindowFrameSaveTask = nil
        saveSettings()
    }

    private func openFromPlaylist(_ url: URL, forceStartAtBeginning: Bool = false) {
        BZLogger.debug("[BZPlayer] openFromPlaylist: \(url.lastPathComponent), forceStartAtBeginning: \(forceStartAtBeginning)")
        clearAudioOnlyModeForMediaChange()
        flushPendingSpeedSave()
        playbackError = nil
        attemptedBackendSwitch = false
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil

        if loopMode == .none && playbackError == nil {
            let settings = Self.loadSettings()
            loopMode = LoopMode(rawValue: settings.loopMode) ?? .playlist
            BZLogger.debug("[BZPlayer] Restored loop mode to: \(loopMode)")
        }

        isPaused = false
        saveCurrentProgress(force: true)
        let isFirstOpen = currentFileURL == nil
        currentFileURL = url
        currentMediaHasAV1Video = false
        openedFilePath = url.path
        openedFiles.insert(url)
        saveOpenedFiles()
        addRecentFile(url)
        currentIndex = playlist.firstIndex(of: url) ?? -1
        currentTime = 0
        duration = 0
        currentVideoSize = nil
        currentNominalFPS = 30
        let discoveredSubtitles = discoverSubtitleFiles(for: url)
        selectedSubtitlePath = pickDefaultSubtitle(for: url, from: discoveredSubtitles)?.path
        // Clear any previous native overlay until the new item is ready.
        clearNativeSubtitleOverlay()
        updateWindowTitle(url.lastPathComponent)
        showToastMessage(url.lastPathComponent)
        applyWindowBehaviorForCurrentMedia(isFirstOpen: isFirstOpen)

        if isFirstOpen {
            if let savedSpeed = loadSpeedForFile(url) {
                speed = Self.normalizeSpeed(savedSpeed)
                BZLogger.debug("[BZPlayer] Restored speed for file: \(savedSpeed)")
            } else {
                let lastUsed = Self.loadSettings().lastUsedSpeed
                speed = Self.normalizeSpeed(lastUsed)
                saveSpeedForFile(url)
                BZLogger.debug("[BZPlayer] Inherited last used speed: \(lastUsed)")
            }
        } else {
            saveSpeedForFile(url)
            BZLogger.debug("[BZPlayer] Keeping current speed: \(speed) for new file")
        }

        if let savedAudioDelay = loadAudioDelayForFile(url) {
            audioDelayMs = savedAudioDelay
        } else {
            audioDelayMs = 0
        }

        let resumeTime = forceStartAtBeginning ? nil : loadSavedProgress(for: url)
        BZLogger.debug("[BZPlayer] resumeTime: \(resumeTime ?? -1)")
        mediaAnalysisTask?.cancel()
        let generation = startNewPlaybackGeneration()
        isSeeking = false
        selectBackend(.native)

        mediaAnalysisTask = Task { @MainActor [weak self] in
            let ffprobeInfo = await probeMediaInfo(url: url)
            guard !Task.isCancelled, let self else { return }
            let backend = await self.chooseBackend(for: url, ffprobeInfo: ffprobeInfo)
            guard !Task.isCancelled,
                  self.mediaOpenGeneration == generation,
                  self.currentFileURL == url else { return }

            let hasAV1Video = await self.hasAV1Video(url: url, ffprobeInfo: ffprobeInfo)
            let nominalFPS = await self.estimateFPS(for: url, ffprobeInfo: ffprobeInfo)
            let videoSize = await self.estimateVideoSize(for: url)
            guard !Task.isCancelled,
                  self.mediaOpenGeneration == generation,
                  self.currentFileURL == url else { return }

            self.currentMediaHasAV1Video = hasAV1Video
            self.currentNominalFPS = nominalFPS
            self.currentVideoSize = videoSize
            self.applyLoadedVideoSizeForCurrentMedia(isFirstOpen: isFirstOpen)
            BZLogger.debug("[BZPlayer] Selected backend: \(backend)")
            self.selectBackend(backend)

            switch backend {
            case .native:
                let needsNativeWarmupReload = await self.shouldRefreshNativeVideoSurface(url: url, ffprobeInfo: ffprobeInfo)
                self.openWithNative(
                    url: url,
                    resumeAt: resumeTime,
                    refreshVideoSurfaceAfterReady: needsNativeWarmupReload,
                    reloadItemAfterReady: needsNativeWarmupReload,
                    generation: generation
                )
            case .vlc:
                self.loadVLC(url: url, resumeAt: resumeTime)
            }

            self.schedulePlaybackFailureCheck(
                for: url,
                backend: backend,
                resumeAt: resumeTime,
                generation: generation
            )
            self.mediaAnalysisTask = nil
        }
    }

    private func loadVLC(url: URL, resumeAt: Double?, startPaused: Bool = false) {
        vlcPlayer.setSpeed(speed)
        vlcPlayer.load(
            url: url,
            resumeAt: resumeAt,
            audioDelayMs: audioDelayMs,
            subtitleFontSize: subtitleFontSize,
            subtitleBackgroundOpacity: subtitleBackgroundOpacity,
            noVideo: isAudioOnlyMode
        )
        if startPaused {
            vlcPlayer.pause()
        } else {
            vlcPlayer.play()
        }
    }

    private func reloadVLCMediaIfNeeded() {
        guard playbackBackend == .vlc, currentFileURL != nil else { return }
        let resumeAt = currentTime > 0 && currentTime < duration ? currentTime : nil
        vlcPlayer.reloadCurrentMedia(
            resumeAt: resumeAt,
            startPaused: isPaused,
            audioDelayMs: audioDelayMs,
            subtitleFontSize: subtitleFontSize,
            subtitleBackgroundOpacity: subtitleBackgroundOpacity,
            noVideo: isAudioOnlyMode
        )
    }

    private func schedulePlaybackFailureCheck(
        for url: URL,
        backend: PlaybackBackend,
        resumeAt: Double?,
        generation: UUID
    ) {
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.checkAndHandlePlaybackFailure(
                    for: url,
                    originalBackend: backend,
                    resumeAt: resumeAt,
                    generation: generation
                )
            }
        }
    }

    private func checkAndHandlePlaybackFailure(
        for url: URL,
        originalBackend: PlaybackBackend,
        resumeAt: Double?,
        generation: UUID
    ) async {
        guard currentFileURL == url,
              playbackBackend == originalBackend,
              mediaOpenGeneration == generation else { return }
        let hasFailed = duration == 0 && (isPaused || currentTime < 0.5)
        guard hasFailed else { return }

        if originalBackend == .native, currentMediaHasAV1Video {
            reportAV1PlaybackFailure(for: url)
            return
        }

        if !attemptedBackendSwitch {
            attemptedBackendSwitch = true
            let newBackend: PlaybackBackend = originalBackend == .native ? .vlc : .native
            let newGeneration = startNewPlaybackGeneration()
            BZLogger.error("Playback failed with \(originalBackend), switching to \(newBackend)")
            selectBackend(newBackend)

            switch newBackend {
            case .native:
                let shouldRefresh = await shouldRefreshNativeVideoSurface(url: url)
                guard currentFileURL == url,
                      playbackBackend == newBackend,
                      mediaOpenGeneration == newGeneration else { return }
                openWithNative(
                    url: url,
                    resumeAt: resumeAt,
                    refreshVideoSurfaceAfterReady: shouldRefresh,
                    generation: newGeneration
                )
            case .vlc:
                loadVLC(url: url, resumeAt: resumeAt)
            }

            schedulePlaybackFailureCheck(
                for: url,
                backend: newBackend,
                resumeAt: resumeAt,
                generation: newGeneration
            )
        } else {
            let errorMsg = "无法播放文件：\(url.lastPathComponent)\n多个播放内核都无法解码此文件。"
            BZLogger.error(errorMsg)
            playbackError = errorMsg
            if loopMode != .none {
                BZLogger.error("Stopping playback sequence due to unplayable file")
                loopMode = .none
            }
            showFileInfo()
        }
    }

    private func openWithNative(
        url: URL,
        resumeAt: Double?,
        startPaused: Bool = false,
        refreshVideoSurfaceAfterReady: Bool = false,
        reloadItemAfterReady: Bool = false,
        generation mediaGeneration: UUID? = nil
    ) {
        let generation = mediaGeneration ?? mediaOpenGeneration
        unbindNativePlayer()
        nativePlayer.pause()
        nativePlayer.replaceCurrentItem(with: nil)
        let player = AVPlayer()
        player.volume = Float(volume / 100.0)
        player.isMuted = isMuted
        nativePlayer = player
        bindNativePlayer(for: player, generation: generation)
        let item = AVPlayerItem(url: url)
        nativeItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackBackend == .native,
                      self.mediaOpenGeneration == generation,
                      item === self.nativePlayer.currentItem else { return }
                if item.status == .readyToPlay {
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite ? max(0, seconds) : 0
                    self.syncText = "播放链路：系统原生"
                    self.playbackEngineStatus = "AVPlayer"
                    if let resumeAt, resumeAt > 0 {
                        await self.nativePlayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                    }
                    // Apply external subtitle for native path (including AV1).
                    if let selectedSubtitlePath = self.selectedSubtitlePath {
                        _ = self.applyNativeExternalSubtitle(path: selectedSubtitlePath)
                    } else {
                        self.clearNativeSubtitleOverlay()
                    }
                    let displayTime: Double
                    if let resumeAt, resumeAt > 0 {
                        displayTime = resumeAt
                    } else {
                        let t = self.nativePlayer.currentTime().seconds
                        displayTime = t.isFinite ? max(0, t) : 0
                    }
                    self.updateNativeSubtitleOverlay(at: displayTime)
                    if startPaused {
                        self.invalidateNativePlaybackRefresh()
                        self.nativePlayer.pause()
                        self.isPaused = true
                    } else {
                        self.isPaused = false
                        self.resumeNativePlaybackAtCurrentTime()
                    }
                    if refreshVideoSurfaceAfterReady {
                        self.refreshNativeVideoSurface(generation: generation)
                    }
                    if reloadItemAfterReady {
                        self.reloadNativeItemAfterWarmup(
                            url: url,
                            resumeAt: resumeAt,
                            startPaused: startPaused,
                            generation: generation
                        )
                    }
                } else if item.status == .failed {
                    BZLogger.error("AVPlayerItem failed: \(String(describing: item.error)); switching to VLC")
                    self.playbackFailureTimer?.invalidate()
                    self.playbackFailureTimer = nil
                    await self.checkAndHandlePlaybackFailure(
                        for: url,
                        originalBackend: .native,
                        resumeAt: resumeAt,
                        generation: generation
                    )
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func chooseBackend(for url: URL, ffprobeInfo: FFprobeInfo? = nil) async -> PlaybackBackend {
        if await hasAV1Video(url: url, ffprobeInfo: ffprobeInfo) {
            // Older VLCKit 3.6 dav1d could crash on macOS 26 while AV1 is playing.
            // Keep AV1 on AVPlayer until VLCKit 4.x AV1 path is re-validated on target OS.
            // Prefer AVPlayer and never route this known codec to VLC.
            return .native
        }
        // MKV, AVI and other containers are not natively supported by AVPlayer on macOS
        let nonNativeContainers: Set<String> = [
            "mkv", "avi", "flv", "wmv", "webm", "rmvb", "ts", "mpeg", "mpg",
            "ogg", "oga", "opus", "wma", "ape", "mka"
        ]
        if nonNativeContainers.contains(url.pathExtension.lowercased()) {
            return .vlc
        }
        // Audio delay still needs VLC. External text subtitles are rendered
        // by the native overlay, so they no longer force a backend switch.
        if audioDelayMs != 0 {
            return .vlc
        }
        if let ffprobeInfo {
            if shouldPreferVLC(ffprobeInfo: ffprobeInfo) {
                return .vlc
            }
            if ffprobeInfo.videoStreams.contains(where: { $0.codecName == "h264" }),
               await hasVideoDecodeErrors(url: url, scanSeconds: 20) {
                BZLogger.debug("[BZPlayer] Detected video decode errors, using VLC/libvlc: \(url.lastPathComponent)")
                return .vlc
            }
        } else if await shouldPreferVLC(asset: AVURLAsset(url: url)) {
            return .vlc
        }
        return .native
    }

    private func hasAV1Video(url: URL, ffprobeInfo: FFprobeInfo? = nil) async -> Bool {
        if ffprobeInfo?.videoStreams.contains(where: { $0.codecName.lowercased() == "av1" }) == true {
            return true
        }

        let asset = AVURLAsset(url: url)
        let av1Subtypes: Set<String> = ["av01", "av1 ", "1va "]
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        for track in tracks {
            guard let formatDescriptions = try? await track.load(.formatDescriptions) else { continue }
            if formatDescriptions.contains(where: { formatDescription in
                av1Subtypes.contains(codecSubtypeString(from: formatDescription))
            }) {
                return true
            }
        }
        return false
    }

    private func reportAV1PlaybackFailure(for url: URL) {
        guard playbackError == nil else { return }
        playbackFailureTimer?.invalidate()
        playbackFailureTimer = nil
        nativePlayer.pause()
        isPaused = true
        loopMode = .none
        playbackError = "无法播放 AV1 文件：\(url.lastPathComponent)\n已阻止回退到 VLC，以避免触发 VLCKit dav1d 解码器崩溃。"
        showFileInfo()
    }

    private func shouldPreferVLC(ffprobeInfo: FFprobeInfo) -> Bool {
        let nativeSafeVideoCodecs: Set<String> = [
            "h264", "hevc", "mpeg4", "mjpeg", "prores", "jpeg2000", "dvvideo", "h263", "av1", "vp9"
        ]
        
        // VP9 may be supported on modern macOS in MP4/WebM containers, but WebM is usually routed to VLC due to container check.
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

    private func shouldPreferVLC(asset: AVURLAsset) async -> Bool {
        let nativeSafeVideoSubtypes: Set<String> = [
            "avc1", "hvc1", "hev1", "mp4v", "jpeg", "mjp2", "apcn", "apcs", "apco", "apch", "ap4h", "dvc ",
            "vp09", "vp9 ", "90pv"
        ]
        let nativeSafeAudioSubtypes: Set<String> = [
            "aac ", "ac-3", "ec-3", "alac", ".mp3", "mp4a",
            "lpcm", "twos", "sowt", "fl32", "fl64", "in24", "in32",
            "opus", "supo"
        ]

        guard let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else {
            return false
        }

        for track in videoTracks {
            guard let formatDescriptions = try? await track.load(.formatDescriptions) else { continue }
            for formatDescription in formatDescriptions {
                let subtype = codecSubtypeString(from: formatDescription)
                if !subtype.isEmpty && !nativeSafeVideoSubtypes.contains(subtype) { return true }
            }
        }

        for track in audioTracks {
            guard let formatDescriptions = try? await track.load(.formatDescriptions) else { continue }
            for formatDescription in formatDescriptions {
                let subtype = codecSubtypeString(from: formatDescription)
                if !subtype.isEmpty && !nativeSafeAudioSubtypes.contains(subtype) { return true }
            }
        }

        return false
    }

    private func codecSubtypeString(from formatDescription: Any) -> String {
        let cfDescription = formatDescription as CFTypeRef
        guard CFGetTypeID(cfDescription) == CMFormatDescriptionGetTypeID() else { return "" }
        let subtype = CMFormatDescriptionGetMediaSubType(cfDescription as! CMFormatDescription)
        return fourCCString(subtype).lowercased()
    }

    private func shouldRefreshNativeVideoSurface(url: URL, ffprobeInfo: FFprobeInfo? = nil) async -> Bool {
        if let ffprobeInfo, ffprobeInfo.videoStreams.contains(where: { $0.codecName == "vp9" }) {
            return true
        }

        let asset = AVURLAsset(url: url)
        let vp9Subtypes: Set<String> = ["vp09", "vp9 ", "90pv"]
        guard let tracks = try? await asset.loadTracks(withMediaType: .video) else { return false }
        for track in tracks {
            guard let formatDescriptions = try? await track.load(.formatDescriptions) else { continue }
            if formatDescriptions.contains(where: { formatDescription in
                vp9Subtypes.contains(codecSubtypeString(from: formatDescription))
            }) {
                return true
            }
        }
        return false
    }

    private func refreshNativeVideoSurface(generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self,
                  self.playbackBackend == .native,
                  self.mediaOpenGeneration == generation else { return }
            BZLogger.debug("[BZPlayer] Refreshing native video surface")
            self.nativePlayerSurfaceRefreshID += 1
        }
    }

    private func reloadNativeItemAfterWarmup(
        url: URL,
        resumeAt: Double?,
        startPaused: Bool,
        generation: UUID
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            guard self.playbackBackend == .native,
                  self.currentFileURL == url,
                  self.mediaOpenGeneration == generation else { return }

            let currentSeconds = self.nativePlayer.currentTime().seconds
            let reloadResumeAt: Double?
            if currentSeconds.isFinite, currentSeconds > 0 {
                reloadResumeAt = currentSeconds
            } else {
                reloadResumeAt = resumeAt
            }

            BZLogger.debug("[BZPlayer] Reloading native VP9 item after AV warmup")
            self.nativeItemStatusObserver = nil
            self.nativePlayer.replaceCurrentItem(with: nil)
            self.openWithNative(
                url: url,
                resumeAt: reloadResumeAt,
                startPaused: startPaused,
                refreshVideoSurfaceAfterReady: true,
                reloadItemAfterReady: false,
                generation: generation
            )
        }
    }

    private func warmupVP9DecoderIfNeeded() {
        guard !Self.hasCompletedNativeVP9Warmup else { return }
        guard let url = Bundle.module.url(forResource: "Resources/vp9_warmup", withExtension: "mp4") else {
            BZLogger.debug("[BZPlayer] VP9 warmup resource not found, skipping")
            return
        }
        Self.hasCompletedNativeVP9Warmup = true
        BZLogger.debug("[BZPlayer] Starting silent VP9 decoder warmup")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        vp9WarmupPlayer = player
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.vp9WarmupPlayer?.pause()
            self?.vp9WarmupPlayer = nil
            BZLogger.debug("[BZPlayer] VP9 decoder warmup complete")
        }
    }

    private func loadPlaylist(with selectedURL: URL) {
        let fm = FileManager.default
        let isDirectory = (try? selectedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let folder = isDirectory ? selectedURL : selectedURL.deletingLastPathComponent()
        let mediaExts: Set<String> = [
            "mp4", "mkv", "mov", "avi", "flv", "wmv", "m4v", "webm", "ts", "mpeg", "mpg",
            "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "wma", "ape", "mka"
        ]

        let urls = (try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let allMedia = urls.filter { url in
            guard mediaExts.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var mediaFiles = allMedia
        if !isDirectory, !mediaFiles.contains(selectedURL) {
            mediaFiles.append(selectedURL)
            mediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        playlist = isDirectory ? mediaFiles : (mediaFiles.isEmpty ? [selectedURL] : mediaFiles)
        currentIndex = playlist.firstIndex(of: selectedURL) ?? (playlist.isEmpty ? -1 : 0)
        if playlistOrder == .descending {
            playlist.reverse()
            currentIndex = playlist.firstIndex(of: selectedURL) ?? (playlist.isEmpty ? -1 : 0)
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

    private func estimateFPS(for url: URL, ffprobeInfo: FFprobeInfo? = nil) async -> Double {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let fps = try? await track.load(.nominalFrameRate) {
            let fps = Double(fps)
            if fps.isFinite, fps > 0 {
                return fps
            }
        }
        if let ffprobeInfo,
           let summary = ffprobeInfo.videoStreams.first?.summary,
           let fps = parseFPS(fromFFprobeSummary: summary) {
            return fps
        }
        return 30
    }

    private func estimateVideoSize(for url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = size.applying(transform)
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
        return settings.progress.isFinite && settings.progress > 0 ? settings.progress : nil
    }

    private func saveCurrentProgressIfNeeded() {
        let now = Date().timeIntervalSince1970
        guard now - lastProgressSaveTime >= progressSaveInterval ||
              abs(currentTime - lastProgressSavePosition) >= progressSaveInterval else {
            return
        }
        saveCurrentProgress(force: true)
    }

    private func saveCurrentProgress(force: Bool = false) {
        guard let url = currentFileURL, currentTime.isFinite, currentTime > 0 else { return }
        if duration > 0 && currentTime >= max(duration - 0.5, 0) {
            return
        }
        if !force {
            saveCurrentProgressIfNeeded()
            return
        }
        var fileSettings = loadFileSettings(for: url)
        fileSettings.progress = currentTime
        saveFileSettings(for: url, fileSettings)
        lastProgressSaveTime = Date().timeIntervalSince1970
        lastProgressSavePosition = currentTime
    }

    private func clearSavedProgress(for url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.progress = 0
        saveFileSettings(for: url, fileSettings)
    }

    private func loadSpeedForFile(_ url: URL) -> Double? {
        let settings = loadFileSettings(for: url)
        return settings.speed.isFinite && settings.speed > 0 ? Self.normalizeSpeed(settings.speed) : nil
    }

    private func saveSpeedForFile(_ url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.speed = speed
        saveFileSettings(for: url, fileSettings)
    }

    private func loadAudioDelayForFile(_ url: URL) -> Double? {
        let settings = loadFileSettings(for: url)
        return settings.audioDelayMs.isFinite && settings.audioDelayMs != 0 ? Self.normalizeAudioDelay(settings.audioDelayMs) : nil
    }

    private func saveAudioDelayForFile(_ url: URL) {
        var fileSettings = loadFileSettings(for: url)
        fileSettings.audioDelayMs = audioDelayMs
        saveFileSettings(for: url, fileSettings)
    }

    private var toastHideWorkItem: DispatchWorkItem?

    func showToastMessage(_ message: String, isSuccess: Bool = false) {
        toastHideWorkItem?.cancel()
        toastMessage = message
        toastIsSuccess = isSuccess
        showToast = true
        let work = DispatchWorkItem { [weak self] in
            self?.showToast = false
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    func fetchPlaylistDuration(for url: URL) async {
        if playlistDurations[url] != nil { return }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds >= 0, playlist.contains(url) {
                playlistDurations[url] = seconds
            }
        } catch {
            BZLogger.debug("Failed to fetch duration for \(url): \(error)")
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

    private func applyLoadedVideoSizeForCurrentMedia(isFirstOpen: Bool) {
        guard let attachedWindow, currentVideoSize != nil else { return }
        switch windowOpenBehavior {
        case .videoSize:
            resizeWindowToVideoSize(attachedWindow)
        case .fitLargest:
            resizeWindowToLargestFit(attachedWindow)
        case .rememberLast:
            if isFirstOpen, Self.loadSettings().lastWindowFrame == nil {
                resizeWindowToLargestFit(attachedWindow)
            }
        case .fullscreen, .maximized:
            break
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
        scheduleWindowFrameSave()
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
            let ffprobeInfo = await probeMediaInfo(url: url)
            let recommendedBackend = await chooseBackend(for: url, ffprobeInfo: ffprobeInfo)

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

            lines.append("建议播放后端：\(recommendedBackend == .native ? "系统原生" : "VLC/libvlc")")
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
                let formatDescriptions = try await videoTrack.load(.formatDescriptions)

                let transformed = size.applying(transform)
                let width = abs(Int(transformed.width.rounded()))
                let height = abs(Int(transformed.height.rounded()))

                lines.append("")
                lines.append("【视频 #\(index + 1)】")
                lines.append("分辨率：\(width)x\(height)")
                lines.append("帧率：\(String(format: "%.3f", fps)) fps")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                lines.append("编码：\(codecDescription(from: formatDescriptions.first, mediaType: "视频"))")
            }

            let audioTracks = tracks.filter { $0.mediaType == .audio }
            lines.append("")
            lines.append("音频轨道：\(audioTracks.count)")
            if audioTracks.isEmpty {
                if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
                    lines.append("提示：AVFoundation 未识别到音轨，但 ffprobe 检测到 \(ffprobeInfo.audioStreams.count) 条音轨。")
                    lines.append("这类文件会自动切到 VLC 后端播放。")
                } else {
                    lines.append("提示：AVFoundation 未检测到音轨。")
                    lines.append("若文件在其它播放器有声音，更可能是当前系统媒体解析兼容性问题。")
                    lines.append("本次未拿到 ffprobe 音轨结果，可能是 ffprobe 不可用、执行失败，或文件读取受限。")
                    lines.append("因此这里不能据此判断源文件就是无声。")
                }
            }

            for (index, audioTrack) in audioTracks.enumerated() {
                let estimatedBitRate = try await audioTrack.load(.estimatedDataRate)
                let formatDescriptions = try await audioTrack.load(.formatDescriptions)
                lines.append("")
                lines.append("【音频 #\(index + 1)】")
                lines.append("码率：\(formatBitrate(estimatedBitRate))")
                if let formatDesc = formatDescriptions.first {
                    let cfDescription = formatDesc as CFTypeRef
                    if CFGetTypeID(cfDescription) == CMFormatDescriptionGetTypeID(),
                       CMFormatDescriptionGetMediaType(cfDescription as! CMFormatDescription) == kCMMediaType_Audio,
                       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cfDescription as! CMAudioFormatDescription)?.pointee {
                    lines.append("采样率：\(Int(asbd.mSampleRate)) Hz")
                    lines.append("声道数：\(asbd.mChannelsPerFrame)")
                    lines.append("位深：\(asbd.mBitsPerChannel) bit")
                    }
                }
                lines.append("编码：\(codecDescription(from: formatDescriptions.first, mediaType: "音频"))")
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
        BZLogger.debug("[BZPlayer] handlePlaybackFinished called - Time: \(snapshotTime), Duration: \(duration), isPaused: \(isPaused), isSeeking: \(isSeeking), loopMode: \(loopMode)")

        // Don't auto-advance if there's a playback error
        if playbackError != nil {
            BZLogger.debug("[BZPlayer] Playback error detected, pausing instead of auto-advancing")
            isPaused = true
            return
        }

        // If duration is 0, try to get it directly from VLC
        var effectiveDuration = duration
        if effectiveDuration == 0 && playbackBackend == .vlc {
            if let vlcDuration = vlcPlayer.getDoubleProperty("duration") {
                effectiveDuration = vlcDuration
                BZLogger.debug("[BZPlayer] Got duration from VLC directly: \(effectiveDuration)")
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

        BZLogger.debug("[BZPlayer] isNearEnd check - duration: \(effectiveDuration), snapshotTime: \(snapshotTime), timeDiff: \(timeDiff), progressPercent: \(progressPercent), result: \(isNearEnd)")
        guard isNearEnd else {
            BZLogger.debug("[BZPlayer] Ignoring playback-finished notification (not near end or invalid duration)")
            if effectiveDuration == 0 {
                BZLogger.debug("[BZPlayer] Duration is 0, treating playback-finished notification as a transient VLC signal")
            }
            return
        }

        // Clear saved progress AFTER guard (we're truly at end), and reset currentTime
        if let url = currentFileURL {
            completedFiles.insert(url)
            saveCompletedFiles()
            clearSavedProgress(for: url)
        }
        currentTime = 0

        // Safety Guard: prevent rapid-fire infinite auto-next loops
        let now = ProcessInfo.processInfo.systemUptime
        lastAutoNextJumpTimes = lastAutoNextJumpTimes.filter { now - $0 < 5.0 }
        lastAutoNextJumpTimes.append(now)

        if lastAutoNextJumpTimes.count > 5 {
            BZLogger.debug("[BZPlayer] DETECTED INFINITE SKIP LOOP! Pausing playback to prevent instability.")
            pause()
            lastAutoNextJumpTimes.removeAll()
            showAlert(title: "播放提示", message: "检测到连续快速切片，可能遇到无法播放的文件，已停止播放以防程序崩溃。")
            return
        }

        // Capture currentFileURL before openFromPlaylist clears/replaces it
        let finishedFileURL = currentFileURL

        switch loopMode {
        case .singleFile:
            BZLogger.debug("[BZPlayer] Loop mode: singleFile")
            if let url = finishedFileURL {
                openFromPlaylist(url, forceStartAtBeginning: true)
            } else {
                isPaused = true
            }
        case .playlist:
            BZLogger.debug("[BZPlayer] Loop mode: playlist, currentFileURL: \(String(describing: finishedFileURL)), currentIndex: \(currentIndex)")
            // Use path comparison to find current index, as URL instances may differ
            let current: Int
            if let currentURL = finishedFileURL {
                current = playlist.firstIndex { $0.path == currentURL.path } ?? currentIndex
            } else {
                current = currentIndex
            }
            BZLogger.debug("[BZPlayer] Calculated current index: \(current), playlist.count: \(playlist.count)")
            let nextIndex = current + 1
            if nextIndex < playlist.count {
                BZLogger.debug("[BZPlayer] Opening next file at index \(nextIndex): \(playlist[nextIndex].lastPathComponent)")
                openFromPlaylist(playlist[nextIndex])
            } else if let first = playlist.first {
                BZLogger.debug("[BZPlayer] At end of playlist, looping back to first: \(first.lastPathComponent)")
                openFromPlaylist(first)
            } else {
                BZLogger.debug("[BZPlayer] Playlist is empty, pausing")
                isPaused = true
            }
        case .none:
            BZLogger.debug("[BZPlayer] Loop mode: none, pausing")
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

    static func clampSubtitlePosition(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0.02), 0.98)
    }

    @discardableResult
    func applyNativeExternalSubtitle(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            // Security-scoped bookmark / permission edge case: try coordinated read via Data.
            if (try? Data(contentsOf: url, options: [.mappedIfSafe])) == nil {
                clearNativeSubtitleOverlay()
                BZLogger.error("[BZPlayer] External subtitle missing or unreadable: \(path)")
                return false
            }
            // File is readable even if fileExists returned false (rare path resolution cases).
            BZLogger.debug("[BZPlayer] External subtitle fileExists=false but Data readable: \(path)")
        }
        guard let cues = ExternalSubtitleParser.loadCues(from: url), !cues.isEmpty else {
            clearNativeSubtitleOverlay()
            BZLogger.error("[BZPlayer] Failed to parse external subtitle or empty: \(path)")
            return false
        }
        nativeSubtitleCues = cues
        nativeSubtitleCueIndex = 0
        // Prefer live player clock when available so overlay matches the frame on screen.
        let clock = playbackBackend == .native ? nativePlayer.currentTime().seconds : currentTime
        let time = clock.isFinite ? max(0, clock) : currentTime
        updateNativeSubtitleOverlay(at: time)
        // Also force a render-id bump so the host view refreshes even if text is still empty
        // (e.g. first cue starts later than current time).
        nativeSubtitleRenderID &+= 1
        BZLogger.info("[BZPlayer] Loaded \(cues.count) native subtitle cues from \(url.lastPathComponent) at t=\(String(format: "%.2f", time)) text=\(nativeSubtitleText.isEmpty ? "<empty>" : nativeSubtitleText)")
        // Persist a tiny breadcrumb for manual verification without Console filters.
        Self.writeSubtitleDebugLog(
            "loaded cues=\(cues.count) file=\(url.lastPathComponent) t=\(String(format: "%.2f", time)) backend=\(playbackBackend.rawValue)"
        )
        return true
    }

    private static func writeSubtitleDebugLog(_ line: String) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = appSupport.appendingPathComponent("BZPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("subtitle-debug.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let data = stamped.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: file.path) {
                if let handle = try? FileHandle(forWritingTo: file) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: file)
            }
        }
    }

    func clearNativeSubtitleOverlay() {
        nativeSubtitleCues = []
        nativeSubtitleCueIndex = 0
        setNativeSubtitleText("")
    }

    private func setNativeSubtitleText(_ text: String) {
        guard nativeSubtitleText != text else { return }
        nativeSubtitleText = text
        nativeSubtitleRenderID &+= 1
    }

    func updateNativeSubtitleOverlay(at time: Double) {
        guard playbackBackend == .native else {
            setNativeSubtitleText("")
            return
        }
        guard !nativeSubtitleCues.isEmpty, time.isFinite else {
            setNativeSubtitleText("")
            return
        }

        // Fast path: reuse the previous cue index when playback is advancing.
        if nativeSubtitleCues.indices.contains(nativeSubtitleCueIndex) {
            let current = nativeSubtitleCues[nativeSubtitleCueIndex]
            if current.contains(time: time) {
                setNativeSubtitleText(current.text)
                return
            }
            if time >= current.end {
                var index = nativeSubtitleCueIndex + 1
                while index < nativeSubtitleCues.count, nativeSubtitleCues[index].end <= time {
                    index += 1
                }
                if index < nativeSubtitleCues.count, nativeSubtitleCues[index].contains(time: time) {
                    nativeSubtitleCueIndex = index
                    setNativeSubtitleText(nativeSubtitleCues[index].text)
                    return
                }
                nativeSubtitleCueIndex = min(index, max(nativeSubtitleCues.count - 1, 0))
                setNativeSubtitleText("")
                return
            }
        }

        if let cue = ExternalSubtitleParser.activeCue(in: nativeSubtitleCues, at: time) {
            if let index = nativeSubtitleCues.firstIndex(where: {
                $0.start == cue.start && $0.end == cue.end && $0.text == cue.text
            }) {
                nativeSubtitleCueIndex = index
            }
            setNativeSubtitleText(cue.text)
        } else {
            setNativeSubtitleText("")
        }
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
        let sorted = sortSubtitles(candidates, for: mediaURL, activeLanguage: getActiveLanguage())
        guard let first = sorted.first else { return nil }
        
        let prio = subtitlePriority(for: first, mediaURL: mediaURL, activeLanguage: getActiveLanguage())
        if prio == 1 || prio == 2 {
            return first
        }
        return nil
    }
}

extension PlayerViewModel {
    // Track selection methods
    private func selectDefaultTracksBySystemLanguage() {
        guard playbackBackend == .vlc else { return }
        
        let activeLang = getActiveLanguage()
        
        // 1. Select Audio Track
        let audioTracks = vlcPlayer.audioTracks
        if !audioTracks.isEmpty {
            let matchedTrack = audioTracks.first(where: { track in
                let name = track.1.lowercased()
                let keywords = languageKeywords(for: activeLang)
                var extraKeywords: [String] = []
                if activeLang == "zh" {
                    extraKeywords = ["mandarin", "cantonese", "国", "汉", "中", "粤", "双"]
                } else if activeLang == "en" {
                    extraKeywords = ["english"]
                } else if activeLang == "ja" {
                    extraKeywords = ["japanese", "日"]
                } else if activeLang == "de" {
                    extraKeywords = ["deutsch", "german", "德"]
                } else if activeLang == "fr" {
                    extraKeywords = ["french", "法"]
                } else if activeLang == "es" {
                    extraKeywords = ["spanish", "西班牙", "西"]
                } else if activeLang == "ru" {
                    extraKeywords = ["russian", "俄"]
                }
                
                let allKeywords = keywords + extraKeywords
                for kw in allKeywords {
                    if name.contains(kw.lowercased()) {
                        return true
                    }
                }
                if activeLang == "en" {
                    return name == "en" || name.hasPrefix("en ") || name.hasSuffix(" en") || name.contains(" en ")
                }
                return false
            })
            if let matchedTrack {
                vlcPlayer.currentAudioIndex = matchedTrack.0
                BZLogger.debug("Auto-selected audio track based on active language (\(activeLang)): \(matchedTrack.1)")
            }
        }
        
        // 2. Select Embedded Subtitle Track (only if no external subtitle was loaded/preferred)
        if selectedSubtitlePath == nil {
            let subtitleTracks = vlcPlayer.subtitleTracks
            if !subtitleTracks.isEmpty {
                let activeTracks = subtitleTracks.filter { $0.0 != -1 }
                let matchedTrack = activeTracks.first(where: { track in
                    let name = track.1.lowercased()
                    let keywords = languageKeywords(for: activeLang)
                    var extraKeywords: [String] = []
                    if activeLang == "zh" {
                        extraKeywords = ["简", "繁", "中", "sc", "tc", "gb", "big5"]
                    } else if activeLang == "en" {
                        extraKeywords = ["english"]
                    } else if activeLang == "ja" {
                        extraKeywords = ["japanese", "日"]
                    } else if activeLang == "de" {
                        extraKeywords = ["deutsch", "german", "德"]
                    } else if activeLang == "fr" {
                        extraKeywords = ["french", "法"]
                    } else if activeLang == "es" {
                        extraKeywords = ["spanish", "西班牙", "西"]
                    } else if activeLang == "ru" {
                        extraKeywords = ["russian", "俄"]
                    }
                    
                    let allKeywords = keywords + extraKeywords
                    for kw in allKeywords {
                        if name.contains(kw.lowercased()) {
                            return true
                        }
                    }
                    if activeLang == "en" {
                        return name == "en" || name.hasPrefix("en ") || name.hasSuffix(" en") || name.contains(" en ")
                    }
                    return false
                })
                if let matchedTrack {
                    vlcPlayer.currentSubtitleIndex = matchedTrack.0
                    BZLogger.debug("Auto-selected embedded subtitle track based on active language (\(activeLang)): \(matchedTrack.1)")
                }
            }
        }
    }

    func audioTrackMenuEntries() -> [TrackMenuEntry] {
        guard playbackBackend == .vlc else { return [] }
        let tracks = vlcPlayer.audioTracks
        let currentIndex = vlcPlayer.currentAudioIndex
        return tracks.map { index, name in
            TrackMenuEntry(id: index, name: name, isSelected: index == currentIndex)
        }
    }

    func selectAudioTrack(id: Int32) {
        guard playbackBackend == .vlc else { return }
        vlcPlayer.currentAudioIndex = id
        showToastMessage(t("音频轨道已切换"))
    }

    func embeddedSubtitleMenuEntries() -> [TrackMenuEntry] {
        guard playbackBackend == .vlc else { return [] }
        let tracks = vlcPlayer.subtitleTracks
        let currentIndex = vlcPlayer.currentSubtitleIndex
        return tracks.map { index, name in
            TrackMenuEntry(id: index, name: name, isSelected: index == currentIndex)
        }
    }

    func selectEmbeddedSubtitle(id: Int32) {
        guard playbackBackend == .vlc else { return }
        vlcPlayer.currentSubtitleIndex = id
        showToastMessage(t("内置字幕已切换"))
    }

    // Track temporary subtitle files to clean up later
    private func convertSubtitleToUTF8(at originalURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: originalURL) else { return nil }
        
        // 1. Try UTF-8 first
        if let _ = String(data: data, encoding: .utf8) {
            return originalURL
        }
        
        // 2. Try GB18030 / GBK
        let gbEncodingRaw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        var decodedString: String? = nil
        if gbEncodingRaw != kCFStringEncodingInvalidId {
            let gbEncoding = String.Encoding(rawValue: gbEncodingRaw)
            if let str = String(data: data, encoding: gbEncoding) {
                decodedString = str
            }
        }
        
        // 3. Fallbacks
        if decodedString == nil {
            let fallbacks: [String.Encoding] = [.utf16, .utf16BigEndian, .utf16LittleEndian, .ascii]
            for encoding in fallbacks {
                if let str = String(data: data, encoding: encoding) {
                    decodedString = str
                    break
                }
            }
        }
        
        guard let content = decodedString else {
            return nil
        }
        
        // Write decoded content to a UTF-8 temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFilename = UUID().uuidString + "." + originalURL.pathExtension
        let tempFileURL = tempDir.appendingPathComponent(tempFilename)
        
        do {
            try content.write(to: tempFileURL, atomically: true, encoding: .utf8)
            subtitleCleanupTracker.add(tempFileURL)
            BZLogger.debug("[BZPlayer] Converted non-UTF8 subtitle to UTF8 at: \(tempFileURL.path)")
            return tempFileURL
        } catch {
            BZLogger.debug("[BZPlayer] Failed to write UTF-8 subtitle: \(error)")
            return nil
        }
    }
}

private final class SubtitleCleanupTracker: @unchecked Sendable {
    private var temporarySubtitleURLs: [URL] = []
    
    func add(_ url: URL) {
        temporarySubtitleURLs.append(url)
    }
    
    func clean() {
        for url in temporarySubtitleURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporarySubtitleURLs.removeAll()
    }
    
    deinit {
        clean()
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}

private func formatDuration(_ time: Double) -> String {
    guard time.isFinite, time >= 0 else { return "00:00" }
    let total = Int(time)
    let s = total % 60
    let m = (total / 60) % 60
    let h = total / 3600
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%02d:%02d", m, s)
}
