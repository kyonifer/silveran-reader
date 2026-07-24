import Foundation
import SilveranKit
import SwiftJava

@JavaClass("com.kyonifer.silveran.platform.AndroidNowPlayingBridge")
open class JavaAndroidNowPlayingBridge: JavaObject {}

extension JavaClass<JavaAndroidNowPlayingBridge> {
    @JavaStaticMethod
    func update(
        _ title: String,
        _ artist: String,
        _ albumTitle: String,
        _ durationSeconds: Double,
        _ elapsedSeconds: Double,
        _ playbackRate: Double,
        _ isPlaying: Bool,
        _ artworkBase64: String,
        _ artworkChanged: Bool,
    )

    @JavaStaticMethod
    func clear()

    @JavaStaticMethod
    func configureCommands(
        _ token: String,
        _ skipForwardSeconds: Double,
        _ skipBackwardSeconds: Double,
        _ supportsChangePlaybackPosition: Bool,
        _ supportsChangePlaybackRate: Bool,
    )

    @JavaStaticMethod
    func teardownCommands(_ token: String)
}

actor AndroidNowPlayingPresenter: NowPlayingPresenting {
    static let shared = AndroidNowPlayingPresenter()

    private var owner: NowPlayingOwner?
    private var commandToken: String?
    private var commandHandler: (@Sendable (RemoteCommand) -> Void)?
    private var cachedArtwork: Data?

    private init() {}

    func update(_ info: NowPlayingInfo, owner: NowPlayingOwner) {
        guard owner == self.owner else { return }
        let artworkChanged = info.artwork != cachedArtwork
        let artworkBase64 = artworkChanged ? (info.artwork?.base64EncodedString() ?? "") : ""

        do {
            try JavaClass<JavaAndroidNowPlayingBridge>().update(
                info.title,
                info.artist ?? "",
                info.albumTitle ?? "",
                bridgeTime(info.duration),
                bridgeTime(info.elapsedTime),
                info.playbackRate,
                info.isPlaying,
                artworkBase64,
                artworkChanged,
            )
            if artworkChanged {
                cachedArtwork = info.artwork
            }
        } catch {
            // A later periodic update will retry, including unchanged artwork.
        }
    }

    func clear(owner: NowPlayingOwner) {
        guard owner == self.owner else { return }
        cachedArtwork = nil
        try? JavaClass<JavaAndroidNowPlayingBridge>().clear()
    }

    func configureCommands(
        owner: NowPlayingOwner,
        skipForwardInterval: TimeInterval,
        skipBackwardInterval: TimeInterval,
        supportsChangePlaybackPosition: Bool,
        supportsChangePlaybackRate: Bool,
        handler: @escaping @Sendable (RemoteCommand) -> Void,
    ) {
        let token = UUID().uuidString
        self.owner = owner
        commandToken = token
        commandHandler = handler
        try? JavaClass<JavaAndroidNowPlayingBridge>().configureCommands(
            token,
            skipForwardInterval,
            skipBackwardInterval,
            supportsChangePlaybackPosition,
            supportsChangePlaybackRate,
        )
    }

    func teardownCommands(owner: NowPlayingOwner) {
        guard owner == self.owner, let token = commandToken else { return }
        self.owner = nil
        commandToken = nil
        commandHandler = nil
        try? JavaClass<JavaAndroidNowPlayingBridge>().teardownCommands(token)
    }

    fileprivate func handleCommand(
        token: String,
        command: String,
        value: Double,
        text: String,
    ) async {
        guard token == commandToken, let commandHandler else { return }

        switch command {
            case "play":
                commandHandler(.play)
            case "pause":
                commandHandler(.pause)
            case "togglePlayPause":
                commandHandler(.togglePlayPause)
            case "skipForward":
                commandHandler(.skipForward(value))
            case "skipBackward":
                commandHandler(.skipBackward(value))
            case "changePlaybackPosition":
                commandHandler(.changePlaybackPosition(value))
            case "changePlaybackRate":
                commandHandler(.changePlaybackRate(value))
            case "selectChapter":
                try? await AudioSessionActor.shared.control(.selectChapter(text))
            case "nextTrack":
                commandHandler(.nextTrack)
            case "previousTrack":
                commandHandler(.previousTrack)
            default:
                break
        }
    }

    private func bridgeTime(_ value: TimeInterval?) -> Double {
        guard let value, value.isFinite, value >= 0 else { return -1 }
        return value
    }
}

/// Kotlin-to-Swift delivery for MediaSession/MediaLibrarySession player commands.
public func androidNowPlayingCommand(
    token: String,
    command: String,
    value: Double,
    text: String,
) async {
    await AndroidNowPlayingPresenter.shared.handleCommand(
        token: token,
        command: command,
        value: value,
        text: text,
    )
}
