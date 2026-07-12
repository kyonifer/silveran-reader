// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SilveranAndroidBridge",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SilveranAndroidBridge", type: .dynamic, targets: ["SilveranAndroidBridge"])
    ],
    dependencies: [
        .package(name: "Silveran", path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-java", exact: "0.4.2"),
    ],
    targets: [
        .target(
            name: "SilveranAndroidBridge",
            dependencies: [
                .product(name: "SilveranKit", package: "Silveran"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            plugins: [
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java")
            ],
        )
    ],
)
