// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CleanUpCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CleanUpCore", targets: ["CleanUpCore"]),
    ],
    targets: [
        .target(name: "CleanUpCore"),
        .testTarget(name: "CleanUpCoreTests", dependencies: ["CleanUpCore"]),
    ],
    swiftLanguageModes: [.v6]
)
