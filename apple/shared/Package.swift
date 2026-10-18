// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomoUI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PomoUI", targets: ["PomoUI"])],
    targets: [
        .target(name: "PomoUI"),
        .testTarget(name: "PomoUITests", dependencies: ["PomoUI"]),
    ]
)
