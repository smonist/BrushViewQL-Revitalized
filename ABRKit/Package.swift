// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ABRKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ABRKit", targets: ["ABRKit"])],
    targets: [
        .target(name: "ABRKit"),
        .testTarget(name: "ABRKitTests", dependencies: ["ABRKit"]),
    ]
)
