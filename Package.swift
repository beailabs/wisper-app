// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wisper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Wisper",
            path: "Sources/Wisper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
