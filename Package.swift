// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskSense",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DiskSense", targets: ["DiskSense"])
    ],
    targets: [
        .executableTarget(
            name: "DiskSense",
            path: "Sources"
        )
    ]
)
