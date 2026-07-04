#if os(watchOS)
import SilveranKit
import SwiftUI

/// Public entry point that the XCode project can call.
@MainActor
public func watchAppEntryPoint(environment: SilveranEnvironment = SilveranEnvironment()) {
    bootstrapApplePlatformDefaultsIfNeeded()
    AppLaunchContext.environment = environment
    SilveranWatchApp.main()
}
#endif
