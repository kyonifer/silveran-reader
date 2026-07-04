// swift-tools-version: 6.2
import PackageDescription

// App shell for the Linux build. This package is never consumed as a dependency,
// so the branch-based swift-cross-ui requirement is legal here (SwiftPM forbids
// unversioned dependencies in transitive position, which is why it cannot live
// in the root manifest).
let package = Package(
    name: "SilveranLinuxApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "SilveranLinuxApp", targets: ["SilveranLinuxApp"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/stackotter/swift-cross-ui.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "SilveranLinuxApp",
            dependencies: [
                .product(name: "SilveranKit", package: "silveran-reader"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources",
        )
    ],
)
