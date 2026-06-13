// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SilveranKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "SilveranKitCommon", targets: ["SilveranKitCommon"]),
        .library(name: "SilveranKitAppModel", targets: ["SilveranKitAppModel"]),
        .library(name: "SilveranKitSwiftUI", targets: ["SilveranKitSwiftUI"]),
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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/kyonifer/StoryAlign.git", from: "1.2.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SilveranKitCommon",
            dependencies: [
                "SilveranKitMacros",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/Common",
            exclude: ["Macros"],
        ),
        .macro(
            name: "SilveranKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Common/Macros",
        ),
        .target(
            name: "SilveranKitSwiftUI",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitAppModel",
            ],
            path: "Sources/SwiftUI",
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
            ],
            path: "Sources/iOSApp",
        ),
        .target(
            name: "SilveranKitMacApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitSwiftUI",
                "SilveranKitContentServer",
                .product(name: "StoryAlignCore", package: "StoryAlign"),
            ],
            path: "Sources/macApp",
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
