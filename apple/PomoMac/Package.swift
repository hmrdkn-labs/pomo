// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomoMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PomoMac", targets: ["PomoMac"])],
    dependencies: [
        .package(path: "../shared"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(name: "PomoMacKit", dependencies: [
            .product(name: "PomoUI", package: "shared"),
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .executableTarget(name: "PomoMac", dependencies: ["PomoMacKit"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PomoMacKitTests", dependencies: ["PomoMacKit"]),
    ]
)
