// swift-tools-version: 5.9
import PackageDescription

// The drag decision is Foundation-only so its file lifecycle can be tested
// independently of AppKit and the application's Xcode dependencies.
let package = Package(
    name: "ScreenshotDragLifecycle",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenshotDragLifecycle", targets: ["ScreenshotDragLifecycle"])
    ],
    targets: [
        .target(
            name: "ScreenshotDragLifecycle",
            path: "boringNotch/components/Screenshots/Services",
            sources: ["ScreenshotDragBatch.swift"]
        ),
        .testTarget(
            name: "ScreenshotDragLifecycleTests",
            dependencies: ["ScreenshotDragLifecycle"],
            path: "Tests/ScreenshotDragLifecycleTests"
        )
    ]
)
