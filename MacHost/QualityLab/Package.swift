// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabletBridgeQualityLab",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "tabletbridge-quality-lab", targets: ["TabletBridgeQualityLab"]),
    ],
    targets: [
        .executableTarget(name: "TabletBridgeQualityLab", path: "Sources"),
    ]
)
