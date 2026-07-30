// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CleanMac", targets: ["CleanMac"])
    ],
    targets: [
        .executableTarget(
            name: "CleanMac",
            path: "Sources"
        )
    ]
)
