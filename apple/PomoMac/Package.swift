// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomoMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PomoMac", targets: ["PomoMac"])],
    dependencies: [.package(path: "../shared")],
    targets: [
        .target(name: "PomoMacKit", dependencies: [.product(name: "PomoUI", package: "shared")]),
        .executableTarget(name: "PomoMac", dependencies: ["PomoMacKit"]),
        .testTarget(name: "PomoMacKitTests", dependencies: ["PomoMacKit"]),
    ]
)
