// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixSnap",
    platforms: [.macOS(.v14)],
    targets: [
        // Platform-independent logic (geometry, naming, later annotations and history),
        // kept free of AppKit so it can be shared with a future Windows build.
        .target(name: "PixSnapCore"),
        // macOS drawing of annotation documents, shared by the editor canvas and image export.
        .target(name: "PixSnapRender", dependencies: ["PixSnapCore"]),
        .executableTarget(name: "PixSnap", dependencies: ["PixSnapCore", "PixSnapRender"]),
        .testTarget(name: "PixSnapCoreTests", dependencies: ["PixSnapCore"]),
        .testTarget(name: "PixSnapRenderTests", dependencies: ["PixSnapRender"]),
    ],
    swiftLanguageModes: [.v5]
)
