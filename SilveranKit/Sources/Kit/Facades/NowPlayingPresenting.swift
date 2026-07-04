import Foundation

public struct NowPlayingInfo: Sendable {
    public var title: String
    public var artist: String?
    public var albumTitle: String?
    public var duration: TimeInterval?
    public var elapsedTime: TimeInterval?
    public var playbackRate: Double
    public var isPlaying: Bool
    /// Encoded image bytes (PNG/JPEG); the platform side decodes.
    public var artwork: Data?

    public init(
        title: String,
        artist: String? = nil,
        albumTitle: String? = nil,
        duration: TimeInterval? = nil,
        elapsedTime: TimeInterval? = nil,
        playbackRate: Double = 1.0,
        isPlaying: Bool = false,
        artwork: Data? = nil,
    ) {
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.artwork = artwork
    }
}

public enum RemoteCommand: Sendable {
    case play
    case pause
    case togglePlayPause
    case skipForward(TimeInterval)
    case skipBackward(TimeInterval)
    case changePlaybackPosition(TimeInterval)
    case changePlaybackRate(Double)
    case nextTrack
    case previousTrack
}

/// System now-playing surface (lock screen, control center, remote commands).
/// A single presenter is shared by whichever player is active.
public protocol NowPlayingPresenting: Sendable {
    func update(_ info: NowPlayingInfo) async
    func clear() async
    /// Registers system remote commands with the given skip intervals and
    /// routes incoming commands to the handler. Unsupported commands are
    /// disabled system-side so the platform UI does not offer them (e.g. the
    /// lock screen scrubber renders inert when position changes are off).
    func configureCommands(
        skipForwardInterval: TimeInterval,
        skipBackwardInterval: TimeInterval,
        supportsChangePlaybackPosition: Bool,
        supportsChangePlaybackRate: Bool,
        handler: @escaping @Sendable (RemoteCommand) -> Void,
    ) async
    func teardownCommands() async
}
