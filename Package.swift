// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clacky",
    platforms: [.macOS(.v13)],
    targets: [
        // Real-time voice mixer, written in C so the audio thread never allocates or locks.
        .target(
            name: "ClackyCore",
            path: "Sources/ClackyCore"
        ),
        .executableTarget(
            name: "Clacky",
            dependencies: ["ClackyCore"],
            path: "Sources/Clacky",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
