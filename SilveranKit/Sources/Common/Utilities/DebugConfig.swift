import Foundation
#if canImport(os)
import os
private let logger = Logger(subsystem: "com.kyonifer.SilveranReader", category: "debug")
#endif

public func debugLog(_ message: String) {
    #if DEBUG
    #if canImport(os)
    logger.debug("\(message, privacy: .public)")
    #else
    print(message)
    #endif
    #endif
}
