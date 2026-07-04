// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Silveran",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "SilveranKit", targets: ["SilveranKit"]),
        .library(name: "SilveranAppleKit", targets: ["SilveranAppleKit"]),
        .library(name: "SilveranContentServer", targets: ["SilveranContentServer"]),
        .library(name: "SilveranReadaloud", targets: ["SilveranReadaloud"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        .package(url: "https://github.com/kyonifer/StoryAlign.git", from: "1.2.4"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SilveranKit",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "SilveranKit/Sources/Kit",
        ),
        .target(
            name: "SilveranAppleKit",
            dependencies: ["SilveranKit"],
            path: "SilveranKit/Sources/AppleKit",
        ),
        .target(
            name: "SilveranContentServer",
            dependencies: [
                "SilveranKit",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "SilveranKit/Sources/ContentServer",
        ),
        .target(
            name: "SilveranReadaloud",
            dependencies: [
                "SilveranKit",
                .product(name: "StoryAlignCore", package: "StoryAlign"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "SilveranKit/Sources/Readaloud",
        ),
        .testTarget(
            name: "SilveranTests",
            dependencies: ["SilveranKit", "SilveranAppleKit"],
            path: "SilveranKit/Tests/SilveranTests",
        ),
    ],
)
