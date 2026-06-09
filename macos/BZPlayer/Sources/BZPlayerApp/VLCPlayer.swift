import AppKit
import Foundation
import VLCKitSPM

@MainActor
final class VLCPlayer: NSObject {
    var onTimeChanged: ((Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?
    var onPauseChanged: ((Bool) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    var onEndReached: (() -> Void)?

    private let mediaPlayer = VLCMediaPlayer()
    private var currentMedia: VLCMedia?
    private var timeObserverToken: NSObjectProtocol?
    private var stateObserverToken: NSObjectProtocol?
    private var pendingResumeAt: Double?
    private var didFireFileLoaded = false

    override init() {
        super.init()
        mediaPlayer.delegate = self
        bindNotifications()
    }

    deinit {
        if let t = timeObserverToken { NotificationCenter.default.removeObserver(t) }
        if let t = stateObserverToken { NotificationCenter.default.removeObserver(t) }
    }

    func attach(to view: VLCVideoView) {
        mediaPlayer.drawable = view
    }

    func load(url: URL, resumeAt: Double?) {
        pendingResumeAt = resumeAt
        didFireFileLoaded = false
        let media = VLCMedia(url: url)
        media.addOption(":subsdec-encoding=GB18030")
        media.addOption(":freetype-font=PingFang SC")
        currentMedia = media
        mediaPlayer.media = media
    }

    func play() {
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func stop() {
        mediaPlayer.stop()
        currentMedia = nil
    }

    func seek(seconds: Double) {
        guard seconds >= 0 else { return }
        let ms = Int32(clamping: Int(seconds * 1000))
        mediaPlayer.time = VLCTime(int: ms)
    }

    func setSpeed(_ speed: Double) {
        mediaPlayer.rate = Float(speed)
    }

    func setVolume(_ volume: Double) {
        mediaPlayer.audio?.volume = Int32(clamping: Int(volume.rounded()))
    }

    func setMuted(_ muted: Bool) {
        mediaPlayer.audio?.isMuted = muted
    }

    func setHardwareDecodingEnabled(_ enabled: Bool) {
        // VLC manages hardware decoding internally
    }

    func setSubtitleBackgroundOpacity(_ percent: Int) {
        // VLC subtitle styling not directly settable via this API
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

        // Fire onFileLoaded once when playback has started and time is advancing
        if !didFireFileLoaded && seconds > 0 {
            didFireFileLoaded = true
            onFileLoaded?()
        }

        // Seek to resume position after first time tick
        if let resumeAt = pendingResumeAt, resumeAt > 0, seconds >= 0 {
            pendingResumeAt = nil
            let ms = Int32(clamping: Int(resumeAt * 1000))
            mediaPlayer.time = VLCTime(int: ms)
        }
    }

    private func handleStateChanged() {
        switch mediaPlayer.state {
        case .playing:
            onPauseChanged?(false)
        case .paused:
            onPauseChanged?(true)
        case .ended, .stopped:
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
