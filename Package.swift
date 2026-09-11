// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Lidfold",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lidfold",
            path: "Sources/Lidfold",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
