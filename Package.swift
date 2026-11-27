// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FirstToken",
    // Only the platforms CI actually builds: macOS (swift build/test) and the iOS Simulator SDK.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FirstToken", targets: ["FirstToken"]),
    ],
    targets: [
        .target(name: "FirstToken"),
        .testTarget(name: "FirstTokenTests", dependencies: ["FirstToken"]),
    ]
)
