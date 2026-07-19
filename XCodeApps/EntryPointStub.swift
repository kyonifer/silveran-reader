import SilveranAppleKit

#if os(macOS)
import SilveranContentServer
#endif
#if os(iOS) || os(macOS)
import SilveranReadaloud
#endif

/// Keep code out of the Xcode project, because LSP can't complete here.
@main
class EntryPointStub {
    static func main() {
        #if os(macOS)
        macAppEntryPoint(
            environment: SilveranEnvironment(
                contentServer: ContentServer(),
                readaloudAligner: ReadaloudEngine(),
                showStorytellerLockup: true,
            )
        )
        #elseif os(iOS)
        iosAppEntryPoint(
            environment: SilveranEnvironment(readaloudAligner: ReadaloudEngine())
        )
        #elseif os(watchOS)
        watchAppEntryPoint()
        #elseif os(tvOS)
        tvAppEntryPoint()
        #endif
    }
}
