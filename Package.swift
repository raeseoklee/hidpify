// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hidpify",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CHiDPIPrivate"),
        .target(
            name: "HidpifyCore",
            dependencies: ["CHiDPIPrivate"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ColorSync"),
            ]
        ),
        .executableTarget(
            name: "hidpify",
            dependencies: [
                "HidpifyCore"
            ]
        ),
        .executableTarget(
            name: "HidpifyApp",
            dependencies: ["HidpifyCore"]
        ),
    ]
)
