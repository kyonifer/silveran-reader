// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SilveranAndroidCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SilveranAndroidCore", type: .dynamic, targets: ["SilveranAndroidCore"])
    ],
    dependencies: [
        .package(name: "Silveran", path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-java", from: "0.1.2"),
    ],
    targets: [
        .target(
            name: "SilveranAndroidCore",
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
