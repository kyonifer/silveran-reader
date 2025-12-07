#if os(macOS)
import SilveranKitMacApp
#elseif os(iOS)
import SilveranKitiOSApp
#elseif os(watchOS)
import SilveranKitWatchApp
#endif

/// Keep code out of the Xcode project, because LSP can't complete here.
@main
class EntryPointStub {
    static func main() {
        #if os(macOS)
        macAppEntryPoint()
        #elseif os(iOS)
        iosAppEntryPoint()
        #elseif os(watchOS)
        watchAppEntryPoint()
        #endif
    }
}
