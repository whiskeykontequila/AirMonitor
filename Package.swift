// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirMonitor",
            path: "Sources/AirMonitor"
        )
    ]
)
