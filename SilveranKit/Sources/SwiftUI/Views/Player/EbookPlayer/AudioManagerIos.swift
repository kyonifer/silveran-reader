#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
class AudioManagerIos {
    weak var mediaOverlayManager: MediaOverlayManager?

    var bookTitle: String?
    var bookAuthor: String?
    var coverImage: UIImage? {
        didSet {
            cachedArtwork = coverImage.map { createArtwork(from: $0) }
        }
    }

    private var cachedArtwork: MPMediaItemArtwork?

    init() {
        debugLog("[AudioManagerIos] Initializing")
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[AudioManagerIos] Audio session configured for playback")

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAudioSessionInterruption),
                name: AVAudioSession.interruptionNotification,
                object: session
            )
            debugLog("[AudioManagerIos] Audio session interruption observer registered")
        } catch {
            debugLog("[AudioManagerIos] Failed to configure audio session: \(error)")
        }
    }

    @objc nonisolated private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        let shouldResume: Bool
        if type == .ended,
           let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            shouldResume = options.contains(.shouldResume)
        } else {
            shouldResume = false
        }

        Task { @MainActor in
            switch type {
            case .began:
                debugLog("[AudioManagerIos] Audio session interrupted - notifying MOM")
                await mediaOverlayManager?.handleExternalPauseCommand()
            case .ended:
                if shouldResume {
                    debugLog("[AudioManagerIos] Audio session interruption ended - should resume")
                    await mediaOverlayManager?.handleExternalPlayCommand()
                } else {
                    debugLog("[AudioManagerIos] Audio session interruption ended - no resume")
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Remote Command Center

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                debugLog("[AudioManagerIos] Remote play command received")
                await self?.mediaOverlayManager?.handleExternalPlayCommand()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                debugLog("[AudioManagerIos] Remote pause command received")
                await self?.mediaOverlayManager?.handleExternalPauseCommand()
            }
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                debugLog("[AudioManagerIos] Remote skip forward command received")
                await self?.mediaOverlayManager?.handleExternalSkipForward(seconds: 15)
            }
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                debugLog("[AudioManagerIos] Remote skip backward command received")
                await self?.mediaOverlayManager?.handleExternalSkipBackward(seconds: 15)
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                debugLog("[AudioManagerIos] Remote seek command received: \(positionEvent.positionTime)")
                await self?.mediaOverlayManager?.handleExternalSeek(to: positionEvent.positionTime)
            }
            return .success
        }

        debugLog("[AudioManagerIos] Remote command center configured")
    }

    // MARK: - Now Playing Info

    func updateNowPlayingInfo(
        currentTime: Double,
        duration: Double,
        chapterLabel: String,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        var info = [String: Any]()

        info[MPMediaItemPropertyTitle] = bookTitle ?? "Silveran Reader"
        info[MPMediaItemPropertyArtist] = chapterLabel
        info[MPMediaItemPropertyAlbumTitle] = bookAuthor ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        if let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Cleanup

    func cleanup() {
        debugLog("[AudioManagerIos] Cleanup")

        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
    }

    // MARK: - Helpers

    nonisolated private func createArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
#endif
