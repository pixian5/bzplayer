import AVFoundation
import CoreMedia
import Foundation

extension PlayerViewModel {
    func bindMpvCallbacks() {
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
            self.syncText = "播放链路：mpv/libmpv"
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
    }

    func bindNativePlayer() {
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
}
