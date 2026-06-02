// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "vx-ui",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VXLib",
            type: .dynamic,
            targets: ["VXLib"]
        ),
        .executable(
            name: "vx-ui",
            targets: ["vx-ui"]
        ),
    ],
    targets: [
        .target(
            name: "VXLib",
            path: "Sources",
            exclude: ["App"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .executableTarget(
            name: "vx-ui",
            dependencies: ["VXLib"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "VXLibTests",
            dependencies: ["VXLib"],
            path: "Tests/VXLibTests"
        )
    ]
)
