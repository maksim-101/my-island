// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyIslandCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyIslandCore", targets: ["MyIslandCore"]),
    ],
    targets: [
        .target(name: "MyIslandCore"),
        .testTarget(
            name: "MyIslandCoreTests",
            dependencies: ["MyIslandCore"]
        ),
    ]
)
