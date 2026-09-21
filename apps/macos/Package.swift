// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SideCursorMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SideCursorCore", targets: ["SideCursorCore"]),
        .executable(name: "SideCursorMac", targets: ["SideCursorMac"])
    ],
    targets: [
        .target(
            name: "SideCursorCore",
            path: "Sources/SideCursorCore",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=minimal"])]
        ),
        .executableTarget(
            name: "SideCursorMac",
            dependencies: ["SideCursorCore"],
            path: "Sources/SideCursorMac",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=minimal"])]
        ),
        .testTarget(
            name: "SideCursorMacTests",
            dependencies: ["SideCursorCore", "SideCursorMac"],
            path: "Tests/SideCursorMacTests"
        )
    ]
)
