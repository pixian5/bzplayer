import AVFoundation
import AVKit
import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    enum PlaybackBackend: String {
        case native
        case mpv
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
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var openedFilePath: String = ""
    @Published var syncText = "播放链路：系统原生"
    @Published var playlist: [URL] = []
    @Published var currentIndex: Int = -1
    @Published var windowTitle = "BZPlayer"
    @Published var fileAssociationStatus = "未执行格式关联"
    @Published var playbackEngineStatus = "播放引擎：AVPlayer"
    @Published var playbackBackend: PlaybackBackend = .native
    @Published var shortcutSeekSeconds: Double
    @Published var shortcutFrameStepCount: Int
    @Published var previousFileKeyCode: UInt16
    @Published var nextFileKeyCode: UInt16
    @Published var playlistOrder: PlaylistOrder
    @Published var loopMode: LoopMode
    @Published var windowOpenBehavior: WindowOpenBehavior
    @Published var allowMultipleWindows: Bool

    let mpvPlayer = MpvPlayer()
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
    private var windowFrameObservers: [NSObjectProtocol] = []
    private var hasAppliedInitialWindowBehavior = false

    private static let shortcutSeekSecondsKey = "settings.shortcutSeekSeconds"
    private static let shortcutFrameStepCountKey = "settings.shortcutFrameStepCount"
    private static let previousFileKeyCodeKey = "settings.previousFileKeyCode"
    private static let nextFileKeyCodeKey = "settings.nextFileKeyCode"
    private static let playlistOrderKey = "settings.playlistOrder"
    private static let loopModeKey = "settings.loopMode"
    private static let windowOpenBehaviorKey = "settings.windowOpenBehavior"
    private static let lastWindowFrameKey = "settings.lastWindowFrame"
    static let allowMultipleWindowsKey = "settings.allowMultipleWindows"

    override init() {
        let storedSeekSeconds = UserDefaults.standard.object(forKey: Self.shortcutSeekSecondsKey) as? Double
        let storedFrameStepCount = UserDefaults.standard.object(forKey: Self.shortcutFrameStepCountKey) as? Int
        let storedPreviousFileKeyCode = UserDefaults.standard.object(forKey: Self.previousFileKeyCodeKey) as? Int
        let storedNextFileKeyCode = UserDefaults.standard.object(forKey: Self.nextFileKeyCodeKey) as? Int
        let storedPlaylistOrder = UserDefaults.standard.string(forKey: Self.playlistOrderKey).flatMap(PlaylistOrder.init(rawValue:))
        let storedLoopMode = UserDefaults.standard.string(forKey: Self.loopModeKey).flatMap(LoopMode.init(rawValue:))
        let storedWindowOpenBehavior = UserDefaults.standard.string(forKey: Self.windowOpenBehaviorKey).flatMap(WindowOpenBehavior.init(rawValue:))
        let storedAllowMultipleWindows = UserDefaults.standard.object(forKey: Self.allowMultipleWindowsKey) as? Bool
        shortcutSeekSeconds = max(storedSeekSeconds ?? 5, 0.1)
        shortcutFrameStepCount = max(storedFrameStepCount ?? 1, 1)
        previousFileKeyCode = UInt16(storedPreviousFileKeyCode ?? 41)
        nextFileKeyCode = UInt16(storedNextFileKeyCode ?? 39)
        playlistOrder = storedPlaylistOrder ?? .ascending
        loopMode = storedLoopMode ?? .playlist
        windowOpenBehavior = storedWindowOpenBehavior ?? .maximized
        allowMultipleWindows = storedAllowMultipleWindows ?? true
        super.init()
        bindMpvCallbacks()
        bindNativePlayer()
        selectBackend(.native)
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
        openFromPlaylist(normalizedURL)
    }

    func play() {
        switch playbackBackend {
        case .native:
            nativePlayer.play()
            nativePlayer.rate = Float(speed)
            isPaused = false
        case .mpv:
            mpvPlayer.play()
            isPaused = false
        }
    }

    func pause() {
        switch playbackBackend {
        case .native:
            nativePlayer.pause()
        case .mpv:
            mpvPlayer.pause()
        }
        isPaused = true
        saveCurrentProgress()
    }

    func prepareForWindowClose() {
        saveCurrentProgress()
        switch playbackBackend {
        case .native:
            nativePlayer.pause()
            nativePlayer.replaceCurrentItem(with: nil)
        case .mpv:
            mpvPlayer.stop()
        }
        currentFileURL = nil
        openedFilePath = ""
        currentTime = 0
        duration = 0
        isPaused = true
        windowTitle = "BZPlayer"
        attachedWindow?.title = windowTitle
    }

    func togglePause() {
        isPaused ? play() : pause()
    }

    func selectPlaylistItem(_ index: Int) {
        guard playlist.indices.contains(index) else { return }
        openFromPlaylist(playlist[index])
    }

    func previousFile() {
        moveInPlaylist(step: -1)
    }

    func nextFile() {
        moveInPlaylist(step: 1)
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let target = duration * progress
        switch playbackBackend {
        case .native:
            nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        case .mpv:
            mpvPlayer.seek(seconds: target)
        }
    }

    func setSpeed(_ value: Double) {
        speed = min(max(value, 0.25), 16)
        if let url = currentFileURL {
            saveSpeedForFile(url)
        }
        switch playbackBackend {
        case .native:
            nativePlayer.rate = isPaused ? 0 : Float(speed)
        case .mpv:
            mpvPlayer.setSpeed(speed)
        }
    }

    func adjustSpeed(by delta: Double) {
        setSpeed((speed + delta).rounded(toPlaces: 2))
    }

    func setShortcutSeekSeconds(_ value: Double) {
        let normalized = max(value, 0.1)
        shortcutSeekSeconds = normalized
        UserDefaults.standard.set(normalized, forKey: Self.shortcutSeekSecondsKey)
    }

    func setShortcutFrameStepCount(_ value: Int) {
        let normalized = max(value, 1)
        shortcutFrameStepCount = normalized
        UserDefaults.standard.set(normalized, forKey: Self.shortcutFrameStepCountKey)
    }

    func setPreviousFileKeyCode(_ value: UInt16) {
        previousFileKeyCode = value
        UserDefaults.standard.set(Int(value), forKey: Self.previousFileKeyCodeKey)
    }

    func setNextFileKeyCode(_ value: UInt16) {
        nextFileKeyCode = value
        UserDefaults.standard.set(Int(value), forKey: Self.nextFileKeyCodeKey)
    }

    func setWindowOpenBehavior(_ behavior: WindowOpenBehavior) {
        windowOpenBehavior = behavior
        UserDefaults.standard.set(behavior.rawValue, forKey: Self.windowOpenBehaviorKey)
        applyInitialWindowBehaviorIfNeeded(force: true)
    }

    func setAllowMultipleWindows(_ value: Bool) {
        allowMultipleWindows = value
        UserDefaults.standard.set(value, forKey: Self.allowMultipleWindowsKey)
    }

    func refreshPreferences() {
        let storedSeekSeconds = UserDefaults.standard.object(forKey: Self.shortcutSeekSecondsKey) as? Double
        let storedFrameStepCount = UserDefaults.standard.object(forKey: Self.shortcutFrameStepCountKey) as? Int
        let storedPreviousFileKeyCode = UserDefaults.standard.object(forKey: Self.previousFileKeyCodeKey) as? Int
        let storedNextFileKeyCode = UserDefaults.standard.object(forKey: Self.nextFileKeyCodeKey) as? Int
        let storedWindowOpenBehavior = UserDefaults.standard.string(forKey: Self.windowOpenBehaviorKey).flatMap(WindowOpenBehavior.init(rawValue:))
        let storedAllowMultipleWindows = UserDefaults.standard.object(forKey: Self.allowMultipleWindowsKey) as? Bool

        shortcutSeekSeconds = max(storedSeekSeconds ?? shortcutSeekSeconds, 0.1)
        shortcutFrameStepCount = max(storedFrameStepCount ?? shortcutFrameStepCount, 1)
        previousFileKeyCode = UInt16(storedPreviousFileKeyCode ?? Int(previousFileKeyCode))
        nextFileKeyCode = UInt16(storedNextFileKeyCode ?? Int(nextFileKeyCode))
        windowOpenBehavior = storedWindowOpenBehavior ?? windowOpenBehavior
        allowMultipleWindows = storedAllowMultipleWindows ?? allowMultipleWindows
    }

    func togglePlaylistOrder() {
        playlist.reverse()
        playlistOrder = playlistOrder == .ascending ? .descending : .ascending
        UserDefaults.standard.set(playlistOrder.rawValue, forKey: Self.playlistOrderKey)
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
        UserDefaults.standard.set(loopMode.rawValue, forKey: Self.loopModeKey)
    }

    func seekBy(seconds delta: Double) {
        guard hasOpenedFile else { return }
        let baseTime = currentTime.isFinite ? currentTime : 0
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, baseTime + delta))
        switch playbackBackend {
        case .native:
            nativePlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            currentTime = target
        case .mpv:
            mpvPlayer.seek(seconds: target)
            currentTime = target
        }
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

    func handleKeyEvent(_ event: NSEvent, in window: NSWindow?) -> Bool {
        // 空格键
        if event.keyCode == 49 {
            togglePause()
            return true
        }
        // Cmd+O
        if event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.option),
           event.keyCode == 31 {
            openFile()
            return true
        }
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else {
            return false
        }
        switch event.keyCode {
        case 123:
            seekBy(seconds: -shortcutSeekSeconds)
            return true
        case 124:
            seekBy(seconds: shortcutSeekSeconds)
            return true
        case 125:
            seekByConfiguredFrameStep(-1)
            return true
        case 126:
            seekByConfiguredFrameStep(1)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            toggleFullscreen(in: window)
            return true
        default:
            if event.keyCode == previousFileKeyCode {
                previousFile()
                return true
            }
            if event.keyCode == nextFileKeyCode {
                nextFile()
                return true
            }
            return false
        }
    }

    func showFileInfo() {
        guard let url = currentFileURL else {
            showAlert(title: "文件信息", message: "当前未打开媒体文件。")
            return
        }

        let wasPlaying = !isPaused
        Task {
            let text = await buildFileInfoText(url: url)
            await MainActor.run {
                self.showAlert(title: "文件信息", message: text)
                if wasPlaying {
                    self.play()
                }
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
            if Int(self.currentTime * 10) % 30 == 0 {
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
            self.syncText = "播放链路：mpv/libmpv"
        }
        mpvPlayer.onStatusChanged = { [weak self] status in
            guard let self, self.playbackBackend == .mpv else { return }
            self.playbackEngineStatus = status
        }
        mpvPlayer.onEndReached = { [weak self] in
            guard let self, self.playbackBackend == .mpv else { return }
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
                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                if Int(self.currentTime * 10) % 30 == 0 {
                    self.saveCurrentProgress()
                }
            }
        }

        nativeEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackBackend == .native else { return }
                guard notification.object as? AVPlayerItem === self.nativePlayer.currentItem else { return }
                self.handlePlaybackFinished()
            }
        }
    }

    private func selectBackend(_ backend: PlaybackBackend) {
        playbackBackend = backend
        switch backend {
        case .native:
            playbackEngineStatus = "播放引擎：AVPlayer"
            syncText = "播放链路：系统原生"
            mpvPlayer.pause()
        case .mpv:
            playbackEngineStatus = "播放引擎：mpv/libmpv"
            syncText = "播放链路：mpv/libmpv"
            nativePlayer.pause()
        }
    }

    private func openFromPlaylist(_ url: URL, forceStartAtBeginning: Bool = false) {
        saveCurrentProgress()
        currentFileURL = url
        openedFilePath = url.path
        currentIndex = playlist.firstIndex(of: url) ?? -1
        currentTime = 0
        duration = 0
        currentVideoSize = estimateVideoSize(for: url)
        currentNominalFPS = estimateFPS(for: url)
        updateWindowTitle(url.lastPathComponent)
        applyWindowBehaviorForCurrentMedia()

        // 恢复该文件记忆的速度
        if let savedSpeed = loadSpeedForFile(url) {
            speed = savedSpeed
        }

        let resumeTime = forceStartAtBeginning ? nil : loadSavedProgress(for: url)
        let ffprobeInfo = probeMediaInfo(url: url)
        let backend = chooseBackend(for: url, ffprobeInfo: ffprobeInfo)
        selectBackend(backend)

        switch backend {
        case .native:
            openWithNative(url: url, resumeAt: resumeTime)
        case .mpv:
            mpvPlayer.setHardwareDecodingEnabled(false)
            mpvPlayer.setSpeed(speed)
            mpvPlayer.load(url: url, resumeAt: resumeTime)
        }
    }

    private func openWithNative(url: URL, resumeAt: Double?) {
        let item = AVPlayerItem(url: url)
        nativeItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playbackBackend == .native else { return }
                if item.status == .readyToPlay {
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite ? max(0, seconds) : 0
                    self.syncText = "播放链路：系统原生"
                    self.playbackEngineStatus = "播放引擎：AVPlayer"
                    self.isPaused = false
                    if let resumeAt, resumeAt > 0 {
                        self.nativePlayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                    }
                    self.nativePlayer.play()
                    self.nativePlayer.rate = Float(self.speed)
                }
            }
        }
        nativePlayer.replaceCurrentItem(with: item)
    }

    private func chooseBackend(for url: URL, ffprobeInfo: FFprobeInfo? = nil) -> PlaybackBackend {
        let asset = AVURLAsset(url: url)
        let ffprobeInfo = ffprobeInfo ?? probeMediaInfo(url: url)

        if let ffprobeInfo, shouldPreferMpv(ffprobeInfo: ffprobeInfo) {
            return .mpv
        }

        if let ffprobeInfo, ffprobeInfo.audioStreams.isEmpty == false {
            let audioTracks = asset.tracks(withMediaType: .audio)
            if audioTracks.isEmpty {
                return .mpv
            }
        }

        return .native
    }

    private func shouldPreferMpv(ffprobeInfo: FFprobeInfo) -> Bool {
        let nativeFragileVideoCodecs: Set<String> = ["vp8", "vp9", "av1", "theora"]
        let nativeFragileVideoTags: Set<String> = ["vp08", "vp09", "av01"]
        let nativeFragileAudioCodecs: Set<String> = ["opus", "vorbis", "flac"]

        if ffprobeInfo.videoStreams.contains(where: {
            nativeFragileVideoCodecs.contains($0.codecName) || nativeFragileVideoTags.contains($0.codecTag)
        }) {
            return true
        }

        if ffprobeInfo.audioStreams.contains(where: {
            nativeFragileAudioCodecs.contains($0.codecName)
        }) {
            return true
        }

        return false
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

    private func updateWindowTitle(_ title: String) {
        windowTitle = title
        attachedWindow?.title = title
    }

    private func progressKey(for url: URL) -> String {
        "playback.progress.\(url.path)"
    }

    private func loadSavedProgress(for url: URL) -> Double? {
        let value = UserDefaults.standard.double(forKey: progressKey(for: url))
        return value > 0 ? value : nil
    }

    private func saveCurrentProgress() {
        guard let url = currentFileURL, currentTime.isFinite, currentTime > 0 else { return }
        UserDefaults.standard.set(currentTime, forKey: progressKey(for: url))
    }

    private func speedKey(for url: URL) -> String {
        "playback.speed.\(url.path)"
    }

    private func loadSpeedForFile(_ url: URL) -> Double? {
        let value = UserDefaults.standard.double(forKey: speedKey(for: url))
        return value > 0 ? value : nil
    }

    private func saveSpeedForFile(_ url: URL) {
        UserDefaults.standard.set(speed, forKey: speedKey(for: url))
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

    private func applyWindowBehaviorForCurrentMedia() {
        guard let attachedWindow else { return }
        switch windowOpenBehavior {
        case .fullscreen:
            enterFullscreenIfNeeded(for: attachedWindow)
        case .maximized:
            maximize(window: attachedWindow)
        case .videoSize:
            resizeWindowToVideoSize(attachedWindow)
        case .rememberLast:
            if !restoreRememberedWindowFrame(on: attachedWindow) {
                resizeWindowToLargestFit(attachedWindow)
            }
        case .fitLargest:
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
        guard let frameString = UserDefaults.standard.string(forKey: Self.lastWindowFrameKey) else { return false }
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
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.lastWindowFrameKey)
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
            let recommendedBackend = chooseBackend(for: url)

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
        switch loopMode {
        case .singleFile:
            if let currentFileURL {
                openFromPlaylist(currentFileURL, forceStartAtBeginning: true)
            } else {
                isPaused = true
            }
        case .playlist:
            let current = currentFileURL.flatMap { playlist.firstIndex(of: $0) } ?? currentIndex
            if playlist.indices.contains(current + 1) {
                openFromPlaylist(playlist[current + 1])
            } else if let first = playlist.first {
                openFromPlaylist(first)
            } else {
                isPaused = true
            }
        case .none:
            isPaused = true
        }
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

private func formatBitrate(_ bitsPerSecond: Float) -> String {
    guard bitsPerSecond > 0 else { return "未知" }
    let mbps = Double(bitsPerSecond) / 1_000_000
    if mbps >= 1 {
        return String(format: "%.2f Mbps", mbps)
    }
    let kbps = Double(bitsPerSecond) / 1_000
    return String(format: "%.0f kbps", kbps)
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func fourCCString(_ code: FourCharCode) -> String {
    let n = Int(code.bigEndian)
    let c1 = Character(UnicodeScalar((n >> 24) & 255)!)
    let c2 = Character(UnicodeScalar((n >> 16) & 255)!)
    let c3 = Character(UnicodeScalar((n >> 8) & 255)!)
    let c4 = Character(UnicodeScalar(n & 255)!)
    let text = String([c1, c2, c3, c4])
    return text.trimmingCharacters(in: .controlCharacters).isEmpty ? "\(code)" : text
}

private func codecDescription(from formatDescription: Any?, mediaType: String) -> String {
    guard let formatDescription else {
        return "未知（\(mediaType)格式描述不可用）"
    }
    let subtype = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
    return "\(fourCCString(subtype)) (\(subtype))"
}

private struct FFprobeInfo {
    let videoStreams: [FFprobeStream]
    let audioStreams: [FFprobeStream]
}

private struct FFprobeStream {
    let codecName: String
    let codecTag: String
    let summary: String
}

private func probeMediaInfo(url: URL) -> FFprobeInfo? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffprobe",
        "-v", "error",
        "-show_entries",
        "stream=codec_name,codec_long_name,codec_type,codec_tag_string,profile,sample_rate,channels,channel_layout,bit_rate,width,height,r_frame_rate:stream_tags=language",
        "-of", "json",
        url.path
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let streams = object["streams"] as? [[String: Any]]
        else {
            return nil
        }

        let mapped = streams.compactMap(ffprobeStreamSummary(from:))
        return FFprobeInfo(
            videoStreams: mapped.filter { $0.type == "video" }.map {
                FFprobeStream(codecName: $0.codecName, codecTag: $0.codecTag, summary: $0.summary)
            },
            audioStreams: mapped.filter { $0.type == "audio" }.map {
                FFprobeStream(codecName: $0.codecName, codecTag: $0.codecTag, summary: $0.summary)
            }
        )
    } catch {
        return nil
    }
}

private func ffprobeStreamSummary(from json: [String: Any]) -> (type: String, codecName: String, codecTag: String, summary: String)? {
    guard let type = json["codec_type"] as? String else { return nil }
    let codecName = (json["codec_name"] as? String)?.lowercased() ?? ""
    let codecTag = (json["codec_tag_string"] as? String)?.lowercased() ?? ""

    var parts: [String] = []
    if let codec = json["codec_name"] as? String {
        if let longName = json["codec_long_name"] as? String, !longName.isEmpty, longName.lowercased() != codec.lowercased() {
            parts.append("编码 \(codec) (\(longName))")
        } else {
            parts.append("编码 \(codec)")
        }
    }
    if let tag = json["codec_tag_string"] as? String, !tag.isEmpty {
        parts.append("标签 \(tag)")
    }
    if let profile = json["profile"] as? String, !profile.isEmpty, profile != "unknown" {
        parts.append("Profile \(profile)")
    }

    if type == "video" {
        if let width = json["width"] as? Int, let height = json["height"] as? Int {
            parts.append("\(width)x\(height)")
        }
        if let frameRate = json["r_frame_rate"] as? String, frameRate != "0/0" {
            parts.append("帧率 \(frameRate)")
        }
    } else if type == "audio" {
        if let sampleRate = json["sample_rate"] as? String, !sampleRate.isEmpty {
            parts.append("采样率 \(sampleRate) Hz")
        }
        if let channels = json["channels"] as? Int {
            parts.append("声道 \(channels)")
        }
        if let channelLayout = json["channel_layout"] as? String, !channelLayout.isEmpty {
            parts.append(channelLayout)
        }
    }

    if let bitRate = json["bit_rate"] as? String, let value = Float(bitRate) {
        parts.append("码率 \(formatBitrate(value))")
    }

    if let tags = json["tags"] as? [String: Any], let language = tags["language"] as? String, !language.isEmpty {
        parts.append("语言 \(language)")
    }

    return (type, codecName, codecTag, parts.joined(separator: "，"))
}

private func parseFPS(fromFFprobeSummary summary: String) -> Double? {
    guard let range = summary.range(of: "帧率 ") else { return nil }
    let suffix = summary[range.upperBound...]
    let token = suffix.split(separator: "，", maxSplits: 1).first.map(String.init) ?? ""
    if token.contains("/") {
        let parts = token.split(separator: "/", maxSplits: 1).compactMap { Double($0) }
        if parts.count == 2, parts[1] != 0 {
            let fps = parts[0] / parts[1]
            return fps.isFinite && fps > 0 ? fps : nil
        }
    }
    if let value = Double(token), value.isFinite, value > 0 {
        return value
    }
    return nil
}
