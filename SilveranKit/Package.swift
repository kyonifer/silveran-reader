// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SilveranKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        .library(name: "SilveranKitCommon", targets: ["SilveranKitCommon"]),
        .library(name: "SilveranKitSwiftUI", targets: ["SilveranKitSwiftUI"]),
        .library(name: "SilveranKitiOSApp", targets: ["SilveranKitiOSApp"]),
        .library(name: "SilveranKitMacApp", targets: ["SilveranKitMacApp"]),
        .library(name: "SilveranKitWatchApp", targets: ["SilveranKitWatchApp"]),
        .executable(name: "SilveranKitLinuxApp", targets: ["SilveranKitLinuxApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/stackotter/swift-cross-ui.git",
            branch: "main"
        ),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
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
            exclude: ["Macros"]
        ),
        .macro(
            name: "SilveranKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ],
            path: "Sources/Common/Macros"
        ),
        .target(
            name: "SilveranKitSwiftUI",
            dependencies: [
                "SilveranKitCommon"
            ],
            path: "Sources/SwiftUI"
        ),
        .target(
            name: "SilveranKitiOSApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitSwiftUI",
            ],
            path: "Sources/iOSApp"
        ),
        .target(
            name: "SilveranKitMacApp",
            dependencies: [
                "SilveranKitCommon",
                "SilveranKitSwiftUI",
            ],
            path: "Sources/macApp"
        ),
        .target(
            name: "SilveranKitWatchApp",
            dependencies: [
                "SilveranKitCommon",
            ],
            path: "Sources/watchApp"
        ),
        .executableTarget(
            name: "SilveranKitLinuxApp",
            dependencies: [
                "SilveranKitCommon",
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources/LinuxApp"
        ),
        /// TODO: Tests would be nice...
        .testTarget(
            name: "SilveranKitTests",
            dependencies: ["SilveranKitMacApp"],
        ),
    ],
)
