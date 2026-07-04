#if os(iOS)
import SilveranKit
import SwiftUI

/// Public entry point that the XCode project can call.
@MainActor
public func iosAppEntryPoint(environment: SilveranEnvironment = SilveranEnvironment()) {
    bootstrapApplePlatformDefaultsIfNeeded()
    AppLaunchContext.environment = environment
    SilveranReaderApp.main()
}
#endif
