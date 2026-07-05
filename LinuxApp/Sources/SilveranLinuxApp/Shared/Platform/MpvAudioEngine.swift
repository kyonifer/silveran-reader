#if canImport(CMpv)
import CMpv
import Foundation
import SilveranKit

enum MpvEngineError: Error {
    case createFailed
    case loadFailed(String)
}

public struct MpvPlayerProvider: AudioPlayerProviding {
    public init() {}

    public func makePlayer(profile: AudioPlaybackProfile) -> any AudioPlaying {
        MpvAudioEngine()
    }

    public func prepareSession(longForm: Bool) async throws {}

    public func deactivateSession() async {}
}

actor MpvAudioEngine: AudioPlaying {
    nonisolated(unsafe) private let ctx: OpaquePointer?
    private var handler: (@Sendable (AudioEngineEvent) -> Void)?
    private var loadContinuation: CheckedContinuation<Void, any Error>?

    init() {
        guard let ctx = mpv_create() else {
            self.ctx = nil
            return
        }
        mpv_set_option_string(ctx, "video", "no")
        mpv_set_option_string(ctx, "ao", "pipewire,pulseaudio,alsa,null")
        mpv_set_option_string(ctx, "keep-open", "no")
        guard mpv_initialize(ctx) >= 0 else {
            mpv_terminate_destroy(ctx)
            self.ctx = nil
            return
        }
        self.ctx = ctx
        Self.startEventThread(ctx: ctx, engine: self)
    }

    deinit {
        if let ctx {
            Self.runCommand(ctx, ["quit"])
            mpv_wakeup(ctx)
        }
    }

    func load(url: URL) async throws -> TimeInterval {
        guard let ctx else { throw MpvEngineError.createFailed }
        let ctxAddress = UInt(bitPattern: ctx)
        let path = url.path
        mpv_set_property_string(ctx, "pause", "yes")
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            loadContinuation = continuation
            let ctx = OpaquePointer(bitPattern: ctxAddress)!
            Self.runCommand(ctx, ["loadfile", path])
        }
        let durationCtx = OpaquePointer(bitPattern: ctxAddress)!
        return Self.getDouble(durationCtx, "duration") ?? 0
    }

    func play() {
        guard let ctx else { return }
        mpv_set_property_string(ctx, "pause", "no")
    }

    func pause() {
        guard let ctx else { return }
        mpv_set_property_string(ctx, "pause", "yes")
    }

    func stop() {
        guard let ctx else { return }
        Self.runCommand(ctx, ["stop"])
    }

    func seek(to seconds: TimeInterval) {
        guard let ctx else { return }
        Self.runCommand(ctx, ["seek", String(seconds), "absolute"])
    }

    var currentTime: TimeInterval {
        guard let ctx else { return 0 }
        return Self.getDouble(ctx, "time-pos") ?? 0
    }

    var duration: TimeInterval {
        guard let ctx else { return 0 }
        return Self.getDouble(ctx, "duration") ?? 0
    }

    func setRate(_ rate: Double) {
        guard let ctx else { return }
        Self.setDouble(ctx, "speed", rate)
    }

    func setVolume(_ volume: Double) {
        guard let ctx else { return }
        Self.setDouble(ctx, "volume", volume * 100)
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioEngineEvent) -> Void) {
        self.handler = handler
    }

    private func handleFileLoaded() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    private func handleEndFile(reason: mpv_end_file_reason) {
        if let continuation = loadContinuation {
            loadContinuation = nil
            continuation.resume(
                throwing: MpvEngineError.loadFailed("end-file reason \(reason.rawValue)")
            )
            return
        }
        if reason == MPV_END_FILE_REASON_EOF {
            handler?(.didFinishPlaying)
        }
    }

    private static func startEventThread(ctx: OpaquePointer, engine: MpvAudioEngine) {
        let box = WeakEngineBox(engine)
        let ctxAddress = UInt(bitPattern: ctx)
        Thread.detachNewThread {
            let ctx = OpaquePointer(bitPattern: ctxAddress)!
            while true {
                guard let event = mpv_wait_event(ctx, 1.0) else { continue }
                let id = event.pointee.event_id
                if id == MPV_EVENT_SHUTDOWN {
                    mpv_terminate_destroy(ctx)
                    return
                }
                guard let engine = box.engine else {
                    mpv_terminate_destroy(ctx)
                    return
                }
                switch id {
                    case MPV_EVENT_FILE_LOADED:
                        Task { await engine.handleFileLoaded() }
                    case MPV_EVENT_END_FILE:
                        var reason = MPV_END_FILE_REASON_ERROR
                        if let data = event.pointee.data {
                            reason =
                                data.assumingMemoryBound(to: mpv_event_end_file.self).pointee.reason
                        }
                        Task { await engine.handleEndFile(reason: reason) }
                    default:
                        break
                }
            }
        }
    }

    private static func runCommand(_ ctx: OpaquePointer, _ args: [String]) {
        let cStrings = args.map { strdup($0) }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        argv.append(nil)
        _ = mpv_command(ctx, &argv)
        for cString in cStrings {
            free(cString)
        }
    }

    private static func getDouble(_ ctx: OpaquePointer, _ name: String) -> Double? {
        var value = Double(0)
        guard mpv_get_property(ctx, name, MPV_FORMAT_DOUBLE, &value) >= 0 else { return nil }
        return value
    }

    private static func setDouble(_ ctx: OpaquePointer, _ name: String, _ value: Double) {
        var value = value
        _ = mpv_set_property(ctx, name, MPV_FORMAT_DOUBLE, &value)
    }
}

private final class WeakEngineBox: @unchecked Sendable {
    weak var engine: MpvAudioEngine?

    init(_ engine: MpvAudioEngine) {
        self.engine = engine
    }
}
#endif
