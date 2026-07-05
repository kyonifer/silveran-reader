// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SilveranLinuxApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SilveranLinuxApp", targets: ["SilveranLinuxApp"])
    ],
    dependencies: [
        .package(name: "Silveran", path: ".."),
        .package(
            url: "https://github.com/moreSwift/swift-cross-ui.git",
            .upToNextMinor(from: "0.8.0"),
        ),
    ],
    targets: [
        .executableTarget(
            name: "SilveranLinuxApp",
            dependencies: [
                .product(name: "SilveranKit", package: "Silveran"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(
                    name: "Gtk",
                    package: "swift-cross-ui",
                    condition: .when(platforms: [.linux]),
                ),
                .product(
                    name: "GtkBackend",
                    package: "swift-cross-ui",
                    condition: .when(platforms: [.linux]),
                ),
                .target(name: "CWebKitGTK", condition: .when(platforms: [.linux])),
                .target(name: "CMpv", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/SilveranLinuxApp",
        ),
        .systemLibrary(
            name: "CWebKitGTK",
            path: "Sources/CWebKitGTK",
            pkgConfig: "webkitgtk-6.0",
            providers: [.apt(["libwebkitgtk-6.0-dev"])],
        ),
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv",
            pkgConfig: "mpv",
            providers: [.apt(["libmpv-dev"])],
        ),
    ],
)
