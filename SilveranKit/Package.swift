// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Set SILVERAN_STORYTELLER_LOCKUP=1 (or true/yes) before `scripts/genxproj` to
// build the Storyteller logo/wordmark lockup into the macOS sidebar header.
// Off by default while it's held back for the current release.
let storytellerLockupEnabled: Bool = {
    guard let value = ProcessInfo.processInfo.environment["SILVERAN_STORYTELLER_LOCKUP"]?
        .lowercased()
    else { return false }
    return ["1", "true", "yes"].contains(value)
}()

let swiftUISettings: [SwiftSetting] =
    storytellerLockupEnabled ? [.define("SHOW_STORYTELLER_LOCKUP")] : []

let package = Package(
    name: "SilveranKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "SilveranKitCommon", targets: ["SilveranKitCommon"]),
        .library(name: "SilveranKitAppModel", targets: ["SilveranKitAppModel"]),
        .library(name: "SilveranKitSwiftUI", targets: ["SilveranKitSwiftUI"]),
        .library(
            name: "SilveranKitReadaloudGenerator",
            targets: ["SilveranKitReadaloudGenerator"],
        ),
        .library(name: "SilveranKitiOSApp", targets: ["SilveranKitiOSApp"]),
        .library(name: "SilveranKitMacApp", targets: ["SilveranKitMacApp"]),
        .library(name: "SilveranKitContentServer", targets: ["SilveranKitContentServer"]),
        .library(name: "SilveranKitWatchApp", targets: ["SilveranKitWatchApp"]),
        .library(name: "SilveranKitTVApp", targets: ["SilveranKitTVApp"]),
        .executable(name: "SilveranKitLinuxApp", targets: ["SilveranKitLinuxApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui.git",
            branch: "main",
        ),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/kyonifer/StoryAlign.git", from: "1.2.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SilveranKitCommon",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/Common",
        ),
        .target(
            name: "SilveranKitSwiftUI",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitAppModel",
            ],
            path: "Sources/SwiftUI",
            swiftSettings: swiftUISettings,
        ),
        .target(
            name: "SilveranKitAppModel",
            dependencies: [
                "SilveranKitCommon"
            ],
            path: "Sources/AppModel",
        ),
        .target(
            name: "SilveranKitiOSApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitSwiftUI",
                "SilveranKitReadaloudGenerator",
            ],
            path: "Sources/iOSApp",
        ),
        .target(
            name: "SilveranKitMacApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitSwiftUI",
                "SilveranKitReadaloudGenerator",
                "SilveranKitContentServer",
            ],
            path: "Sources/macApp",
        ),
        .target(
            name: "SilveranKitReadaloudGenerator",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitAppModel",
                "SilveranKitSwiftUI",
                .product(name: "StoryAlignCore", package: "StoryAlign"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/ReadaloudGenerator",
        ),
        .target(
            name: "SilveranKitContentServer",
            dependencies: [
                "SilveranKitCommon",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/ContentServer",
        ),
        .target(
            name: "SilveranKitWatchApp",
            dependencies: [
                "SilveranKitCommon"
            ],
            path: "Sources/watchApp",
        ),
        .target(
            name: "SilveranKitTVApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitAppModel",
            ],
            path: "Sources/tvApp",
        ),
        .executableTarget(
            name: "SilveranKitLinuxApp",
            dependencies: [
                "SilveranKitCommon",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources/LinuxApp",
        ),
        /// TODO: Tests would be nice...
        .testTarget(
            name: "SilveranKitTests",
            dependencies: ["SilveranKitCommon", "SilveranKitMacApp"],
        ),
    ],
)
