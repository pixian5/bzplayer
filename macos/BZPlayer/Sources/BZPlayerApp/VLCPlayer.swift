import AppKit
import Foundation
import VLCKitSPM
import CoreText

@MainActor
final class VLCPlayer: NSObject {
    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onEndReached: (() -> Void)?

    private let mediaPlayer: VLCMediaPlayer
    private var currentMedia: VLCMedia?
    private var timeObserverToken: NSObjectProtocol?
    private var stateObserverToken: NSObjectProtocol?
    private var pendingResumeAt: Double?
    private var didFireFileLoaded = false
    private var wasPlayingBeforeSeek: Bool?
    private var pendingPlayTask: Task<Void, Never>?
    private var currentURL: URL?
    private var configuredAudioDelayMs: Double = 0
    private var configuredSubtitleFontSize = 55
    private var configuredSubtitleBackgroundOpacity = 0
    private weak var currentAttachedView: VLCVideoView?

    override init() {
        let library = VLCLibrary(options: [
            "--freetype-font=/System/Library/Fonts/STHeiti Light.ttc",
            "--subsdec-encoding=GB18030",
            "--avcodec-hw=any"
        ])
        self.mediaPlayer = VLCMediaPlayer(library: library)
        super.init()
        mediaPlayer.delegate = self
        bindNotifications()
        registerCustomFonts()
    }

    deinit {
        pendingPlayTask?.cancel()
        if let t = timeObserverToken { NotificationCenter.default.removeObserver(t) }
        if let t = stateObserverToken { NotificationCenter.default.removeObserver(t) }
    }

    func attach(to view: VLCVideoView) {
        guard currentAttachedView !== view else { return }
        currentAttachedView = view
        mediaPlayer.drawable = view
    }

    func load(
        url: URL,
        resumeAt: Double?,
        audioDelayMs: Double = 0,
        subtitleFontSize: Int = 55,
        subtitleBackgroundOpacity: Int = 0
    ) {
        cancelPendingPlay()
        pendingResumeAt = resumeAt
        didFireFileLoaded = false
        currentURL = url
        configuredAudioDelayMs = audioDelayMs
        configuredSubtitleFontSize = max(1, subtitleFontSize)
        configuredSubtitleBackgroundOpacity = min(max(subtitleBackgroundOpacity, 0), 100)
        let media = VLCMedia(url: url)
        media.addOption(":subsdec-encoding=GB18030")
        media.addOption(":freetype-font=/System/Library/Fonts/STHeiti Light.ttc")
        media.addOption(":freetype-rel-fontsize=\(configuredSubtitleFontSize)")
        media.addOption(":freetype-background-opacity=\(configuredSubtitleBackgroundOpacity * 255 / 100)")
        media.addOption(":avcodec-hw=any")
        media.addOption(":codec=videotoolbox")
        currentMedia = media
        mediaPlayer.media = media
    }

    func play() {
        cancelPendingPlay()
        mediaPlayer.play()
    }

    func pause() {
        cancelPendingPlay()
        mediaPlayer.pause()
    }

    func stop() {
        cancelPendingPlay()
        mediaPlayer.stop()
        mediaPlayer.media = nil
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
        mediaPlayer.rate = Float(speed)
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
        let microseconds = (delayMs * 1_000).rounded()
        if microseconds >= Double(Int.max) {
            mediaPlayer.currentAudioPlaybackDelay = Int.max
        } else if microseconds <= Double(Int.min) {
            mediaPlayer.currentAudioPlaybackDelay = Int.min
        } else {
            mediaPlayer.currentAudioPlaybackDelay = Int(microseconds)
        }
    }

    func reloadCurrentMedia(
        resumeAt: Double?,
        startPaused: Bool,
        audioDelayMs: Double,
        subtitleFontSize: Int,
        subtitleBackgroundOpacity: Int
    ) {
        guard let currentURL else { return }
        load(
            url: currentURL,
            resumeAt: resumeAt,
            audioDelayMs: audioDelayMs,
            subtitleFontSize: subtitleFontSize,
            subtitleBackgroundOpacity: subtitleBackgroundOpacity
        )
        if startPaused {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }

    func setHardwareDecodingEnabled(_ enabled: Bool) {
        // VLC manages hardware decoding internally
    }

    func setExternalSubtitle(url: URL) {
        mediaPlayer.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }

    func disableSubtitle() {
        mediaPlayer.currentVideoSubTitleIndex = -1
    }

    var subtitleTracks: [(Int32, String)] {
        guard let names = mediaPlayer.videoSubTitlesNames as? [String],
              let indexes = mediaPlayer.videoSubTitlesIndexes as? [NSNumber],
              names.count == indexes.count else {
            return []
        }
        return zip(indexes.map { $0.intValue }, names).map { (Int32($0), $1) }
    }

    var currentSubtitleIndex: Int32 {
        get {
            return mediaPlayer.currentVideoSubTitleIndex
        }
        set {
            mediaPlayer.currentVideoSubTitleIndex = newValue
        }
    }

    var audioTracks: [(Int32, String)] {
        guard let names = mediaPlayer.audioTrackNames as? [String],
              let indexes = mediaPlayer.audioTrackIndexes as? [NSNumber],
              names.count == indexes.count else {
            return []
        }
        return zip(indexes.map { $0.intValue }, names).map { (Int32($0), $1) }
    }

    var currentAudioIndex: Int32 {
        get {
            return mediaPlayer.currentAudioTrackIndex
        }
        set {
            mediaPlayer.currentAudioTrackIndex = newValue
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
            print("[BZPlayer] Bundled simhei.ttf not found in module or main bundle")
            return
        }
        
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            print("[BZPlayer] Successfully registered bundled simhei.ttf: \(url.path)")
        } else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            print("[BZPlayer] Failed to register bundled simhei.ttf: \(errorDesc)")
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
        let center = NotificationCenter.default
        timeObserverToken = center.addObserver(
            forName: Notification.Name(VLCMediaPlayerTimeChanged),
            object: mediaPlayer,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.handleTimeChanged() }
        }
        stateObserverToken = center.addObserver(
            forName: Notification.Name(VLCMediaPlayerStateChanged),
            object: mediaPlayer,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.handleStateChanged() }
        }
    }

    private func handleTimeChanged() {
        setAudioDelay(configuredAudioDelayMs)
        let ms = mediaPlayer.time.value?.doubleValue ?? 0
        let seconds = ms / 1000.0
        onTimeChanged?(seconds)

        // Emit duration once it becomes available
        if let media = currentMedia {
            let durationMs = media.length.value?.doubleValue ?? 0
            if durationMs > 0 {
                onDurationChanged?(durationMs / 1000.0)
            }
        }

        fireFileLoadedIfReady()

        // Seek to resume position after first time tick
        if let resumeAt = pendingResumeAt, resumeAt > 0, seconds >= 0 {
            pendingResumeAt = nil
            let ms = milliseconds(for: resumeAt)
            mediaPlayer.time = VLCTime(int: ms)
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

    private func fireFileLoadedIfReady() {
        guard !didFireFileLoaded, currentMedia != nil else { return }
        let durationMs = currentMedia?.length.value?.doubleValue ?? 0
        guard durationMs > 0 || mediaPlayer.state == .playing else { return }
        didFireFileLoaded = true
        onFileLoaded?()
    }

    private func handleStateChanged() {
        switch mediaPlayer.state {
        case .playing:
            fireFileLoadedIfReady()
            onPauseChanged?(false)
        case .paused:
            fireFileLoadedIfReady()
            onPauseChanged?(true)
        case .ended:
            onEndReached?()
        case .error:
            onEndReached?()
        default:
            break
        }
    }
}

extension VLCPlayer: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        // Handled via NotificationCenter observer on main queue
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        // Handled via NotificationCenter observer on main queue
    }
}
