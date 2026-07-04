#if os(tvOS)
import SilveranKit
import SwiftUI

/// Public entry point that the XCode project can call.
@MainActor
public func tvAppEntryPoint(environment: SilveranEnvironment = SilveranEnvironment()) {
    bootstrapApplePlatformDefaultsIfNeeded()
    AppLaunchContext.environment = environment
    SilveranTVApp.main()
}
#endif
