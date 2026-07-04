#if canImport(AVFoundation)
import AVFoundation
import Foundation

public enum AudioSessionError: Error, LocalizedError {
    case activationFailed

    public var errorDescription: String? {
        switch self {
            case .activationFailed:
                return "Audio session activation returned false"
        }
    }
}

public actor ApplePlayerProvider: AudioPlayerProviding {
    #if os(watchOS)
    private var longFormUnavailable = false
    #endif

    public init() {}

    nonisolated public func makePlayer(profile: AudioPlaybackProfile) -> any AudioPlaying {
        switch profile {
            case .smilSegment:
                return AVPlayerAudioEngine()
            case .audiobookTrack:
                return AVAudioPlayerAudioEngine()
        }
    }

    public func prepareSession(longForm: Bool) async {
        #if os(watchOS)
        let session = AVAudioSession.sharedInstance()

        if longForm && !longFormUnavailable {
            do {
                // longFormAudio is required for watchOS background playback. Long-form
                // activation is asynchronous and may present a route picker.
                try session.setCategory(
                    .playback,
                    mode: .spokenAudio,
                    policy: .longFormAudio,
                    options: [],
                )
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    session.activate(options: []) { success, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if success {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: AudioSessionError.activationFailed)
                        }
                    }
                }
                debugLog("[ApplePlayerProvider] Long-form audio session activated")
                return
            } catch {
                // No eligible long-form route (older watch hardware with no Bluetooth
                // device paired). Fall back to the default policy so speaker playback
                // still works, accepting that audio stops when the app backgrounds.
                debugLog(
                    "[ApplePlayerProvider] Long-form activation failed, using default policy: \(error)"
                )
                longFormUnavailable = true
            }
        }

        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[ApplePlayerProvider] Audio session activated")
        } catch {
            debugLog("[ApplePlayerProvider] Failed to activate audio session: \(error)")
        }
        #elseif os(iOS) || os(tvOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            debugLog("[ApplePlayerProvider] Audio session activated")
        } catch {
            debugLog("[ApplePlayerProvider] Failed to activate audio session: \(error)")
        }
        #endif
    }

    public func deactivateSession() {
        #if os(iOS) || os(watchOS) || os(tvOS)
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation,
            )
        } catch {
            debugLog("[ApplePlayerProvider] Failed to deactivate audio session: \(error)")
        }
        #endif
    }
}

#if os(iOS) || os(watchOS) || os(tvOS)
private func audioInterruptionEvent(from notification: Notification) -> AudioEngineEvent? {
    guard let userInfo = notification.userInfo,
        let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
        return nil
    }

    switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let shouldResume: Bool
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = false
            }
            return .interruptionEnded(shouldResume: shouldResume)
        @unknown default:
            return nil
    }
}

private func audioRouteChangeEvent(from notification: Notification) -> AudioEngineEvent? {
    guard let userInfo = notification.userInfo,
        let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else {
        return nil
    }

    switch reason {
        case .oldDeviceUnavailable:
            return .routeChanged(shouldPause: true)
        default:
            return nil
    }
}
#endif

// Notification tokens live here rather than on the engine actors because actor
// deinits cannot touch non-Sendable stored state; the bag's own deinit removes
// the observers when the engine deallocates.
private final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty
    }

    func add(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let removed = tokens
        tokens = []
        lock.unlock()
        for token in removed {
            NotificationCenter.default.removeObserver(token)
        }
    }

    deinit {
        removeAll()
    }
}

actor AVPlayerAudioEngine: AudioPlaying {
    private var player: AVPlayer?
    private let endObserverBag = NotificationObserverBag()
    private var desiredRate: Double = 1.0
    private var desiredVolume: Double = 1.0
    private var isPlaying = false
    private var eventHandler: (@Sendable (AudioEngineEvent) -> Void)?

    #if os(iOS) || os(watchOS) || os(tvOS)
    private let sessionObserverBag = NotificationObserverBag()
    #endif

    func load(url: URL) async throws -> TimeInterval {
        teardownPlayer()
        configureSessionObserversIfNeeded()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.rate = 0  // Start paused
        newPlayer.volume = Float(desiredVolume)

        endObserverBag.add(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: nil,
            ) { [weak self] _ in
                debugLog("[AVPlayerAudioEngine] Audio finished playing")
                guard let self else { return }
                Task { await self.emit(.didFinishPlaying) }
            }
        )

        player = newPlayer

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        debugLog(
            "[AVPlayerAudioEngine] Audio loaded, duration: \(duration.isNaN ? 0 : duration)s"
        )
        return duration.isFinite && duration > 0 ? duration : 0
    }

    func play() {
        guard let player else { return }
        player.rate = Float(desiredRate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        teardownPlayer()
    }

    func seek(to seconds: TimeInterval) async {
        guard let player else { return }
        await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
    }

    var currentTime: TimeInterval {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    var duration: TimeInterval {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    func setRate(_ rate: Double) {
        desiredRate = rate
        if isPlaying {
            player?.rate = Float(rate)
        }
    }

    func setVolume(_ volume: Double) {
        desiredVolume = volume
        player?.volume = Float(volume)
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioEngineEvent) -> Void) {
        eventHandler = handler
    }

    private func emit(_ event: AudioEngineEvent) {
        eventHandler?(event)
    }

    private func teardownPlayer() {
        endObserverBag.removeAll()
        player?.pause()
        player = nil
        isPlaying = false
    }

    #if os(iOS) || os(watchOS) || os(tvOS)
    private func configureSessionObserversIfNeeded() {
        guard sessionObserverBag.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()

        sessionObserverBag.add(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: nil,
            ) { [weak self] notification in
                guard let self, let event = audioInterruptionEvent(from: notification) else {
                    return
                }
                Task { await self.emit(event) }
            }
        )

        sessionObserverBag.add(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: nil,
            ) { [weak self] notification in
                guard let self, let event = audioRouteChangeEvent(from: notification) else {
                    return
                }
                Task { await self.emit(event) }
            }
        )

        debugLog("[AVPlayerAudioEngine] Audio session observers registered")
    }
    #else
    private func configureSessionObserversIfNeeded() {}
    #endif
}

private final class AudioPlayerFinishRelay: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

actor AVAudioPlayerAudioEngine: AudioPlaying {
    private var player: AVAudioPlayer?
    private let finishRelay = AudioPlayerFinishRelay()
    private var desiredRate: Float = 1.0
    private var desiredVolume: Float = 1.0
    private var eventHandler: (@Sendable (AudioEngineEvent) -> Void)?

    #if os(iOS) || os(watchOS) || os(tvOS)
    private let sessionObserverBag = NotificationObserverBag()
    #endif

    func load(url: URL) throws -> TimeInterval {
        player?.stop()
        player = nil
        configureSessionObserversIfNeeded()

        if finishRelay.onFinish == nil {
            finishRelay.onFinish = { [weak self] in
                debugLog("[AVAudioPlayerAudioEngine] Audio finished playing")
                guard let self else { return }
                Task { await self.emit(.didFinishPlaying) }
            }
        }

        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.prepareToPlay()
        newPlayer.enableRate = true
        newPlayer.rate = desiredRate
        newPlayer.volume = desiredVolume
        newPlayer.delegate = finishRelay
        player = newPlayer

        return newPlayer.duration
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func seek(to seconds: TimeInterval) {
        player?.currentTime = max(0, seconds)
    }

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var duration: TimeInterval {
        player?.duration ?? 0
    }

    func setRate(_ rate: Double) {
        desiredRate = Float(rate)
        player?.rate = Float(rate)
    }

    func setVolume(_ volume: Double) {
        desiredVolume = Float(volume)
        player?.volume = Float(volume)
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioEngineEvent) -> Void) {
        eventHandler = handler
    }

    private func emit(_ event: AudioEngineEvent) {
        eventHandler?(event)
    }

    #if os(iOS) || os(watchOS) || os(tvOS)
    private func configureSessionObserversIfNeeded() {
        guard sessionObserverBag.isEmpty else { return }

        let session = AVAudioSession.sharedInstance()

        sessionObserverBag.add(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: nil,
            ) { [weak self] notification in
                guard let self, let event = audioInterruptionEvent(from: notification) else {
                    return
                }
                Task { await self.emit(event) }
            }
        )

        sessionObserverBag.add(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: nil,
            ) { [weak self] notification in
                guard let self, let event = audioRouteChangeEvent(from: notification) else {
                    return
                }
                Task { await self.emit(event) }
            }
        )

        debugLog("[AVAudioPlayerAudioEngine] Audio session observers registered")
    }
    #else
    private func configureSessionObserversIfNeeded() {}
    #endif
}
#endif
