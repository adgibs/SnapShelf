// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SnapShelf",
    platforms: [.macOS(.v14)],
    targets: [
        // Shared model: settings, hotkey model, image encoding, file naming, drag source.
        .target(name: "SnapShelfKit"),
        // History store and the menu bar history UI.
        .target(name: "SnapShelfHistory", dependencies: ["SnapShelfKit"]),
        // ScreenCaptureKit capture and the selection overlays.
        .target(name: "SnapShelfCapture", dependencies: ["SnapShelfKit"]),
        // Quick access overlay (floating thumbnails).
        .target(name: "SnapShelfOverlay", dependencies: ["SnapShelfKit"]),
        // Settings window.
        .target(name: "SnapShelfSettings", dependencies: ["SnapShelfKit"]),
        // Annotation editor.
        .target(name: "SnapShelfAnnotate", dependencies: ["SnapShelfKit"]),
        .executableTarget(
            name: "SnapShelf",
            dependencies: [
                "SnapShelfKit", "SnapShelfHistory", "SnapShelfCapture",
                "SnapShelfOverlay", "SnapShelfSettings", "SnapShelfAnnotate",
            ]
        ),
        .testTarget(
            name: "SnapShelfTests",
            dependencies: ["SnapShelfKit", "SnapShelfHistory", "SnapShelfAnnotate"]
        ),
    ]
)
