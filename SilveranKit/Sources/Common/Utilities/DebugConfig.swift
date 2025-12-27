import Foundation

#if canImport(os)
import os
private let logger = Logger(subsystem: "com.kyonifer.SilveranReader", category: "debug")
#endif

public final class DebugLogBuffer: @unchecked Sendable {
    public static let shared = DebugLogBuffer()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxSize = 2000

    private init() {}

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(message)
        if buffer.count > maxSize {
            buffer.removeFirst()
        }
    }

    public func getMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
    }
}

public func debugLog(_ message: String) {
    DebugLogBuffer.shared.append(message)

    #if DEBUG
    #if canImport(os)
    logger.debug("\(message, privacy: .public)")
    #else
    print(message)
    #endif
    #endif
}
