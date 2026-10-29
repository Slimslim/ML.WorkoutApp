// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BarPathKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BarPathKit", targets: ["BarPathKit"])
    ],
    targets: [
        .target(
            name: "BarPathKit",
            path: "Sources/BarPathKit"
        ),
        .testTarget(
            name: "BarPathKitTests",
            dependencies: ["BarPathKit"],
            path: "Tests/BarPathKitTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
