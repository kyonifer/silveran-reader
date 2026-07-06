import Dispatch
import Foundation
import SilveranKit

public func coreVersion() -> String {
    "SilveranKit on Android (Swift 6.2 runtime, jextract JNI bridge)"
}

public func extractBookMetadata(path: String) -> String {
    let fileURL = URL(fileURLWithPath: path)

    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox(errorJSON("unknown failure"))
    Task.detached {
        defer { semaphore.signal() }
        do {
            let metadata = try await LocalLibraryManager()
                .extractMetadata(from: fileURL, category: .ebook)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            box.value = String(decoding: data, as: UTF8.self)
        } catch {
            box.value = errorJSON(String(describing: error))
        }
    }
    semaphore.wait()
    return box.value
}

// Written once by the detached task before the semaphore is signaled, then
// read by the blocked JNI thread; the semaphore orders the accesses.
private final class ResultBox: @unchecked Sendable {
    var value: String
    init(_ value: String) { self.value = value }
}

private func errorJSON(_ message: String) -> String {
    let escaped = message
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"error\":\"\(escaped)\"}"
}
