#if os(macOS)
import SilveranKit
import SwiftUI

/// Public entry point that the XCode project can call.
@MainActor
public func macAppEntryPoint(environment: SilveranEnvironment = SilveranEnvironment()) {
    AppLaunchContext.environment = environment
    SilveranReaderApp.main()
}

#endif
