// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MDViewer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Native terminal emulator with a real pseudo-terminal (MIT).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        // Pure logic with no UI: file watching, folder scanning, link routing, shell environment.
        .target(name: "MDViewerCore"),
        // The AppKit application.
        .executableTarget(
            name: "MDViewer",
            dependencies: ["MDViewerCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "MDViewerCoreTests", dependencies: ["MDViewerCore"]),
    ]
)
