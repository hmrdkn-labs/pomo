// swift-tools-version: 6.0
import PackageDescription

// PomoFFI.xcframework is built by scripts/build-xcframework.sh (it is not checked in).
let package = Package(
    name: "PomoKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        // The Core and Sync node in-process, as PomoUI's API protocols. App only.
        .library(name: "PomoKit", targets: ["PomoKit"]),
        // Pure Swift (no Rust): alert, Live Activity and widget logic. Shared by the app and the widget extension.
        .library(name: "PomoLive", targets: ["PomoLive"]),
    ],
    dependencies: [
        .package(path: "../shared"),
    ],
    targets: [
        .binaryTarget(name: "PomoFFI", path: "PomoFFI.xcframework"),
        // UniFFI-generated Swift (scripts/build-xcframework.sh rewrites it).
        .target(
            name: "PomoCoreFFI",
            dependencies: ["PomoFFI"],
            // Generated code predates Swift 6 strict concurrency.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "PomoLive",
            dependencies: [.product(name: "PomoUI", package: "shared")]
        ),
        .target(
            name: "PomoKit",
            dependencies: [
                "PomoCoreFFI", "PomoLive",
                .product(name: "PomoUI", package: "shared"),
            ]
        ),
        .testTarget(
            name: "PomoLiveTests",
            dependencies: ["PomoLive", .product(name: "PomoUI", package: "shared")]
        ),
        .testTarget(
            name: "PomoKitTests",
            dependencies: ["PomoKit", "PomoCoreFFI", .product(name: "PomoUI", package: "shared")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
