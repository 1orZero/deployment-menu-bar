// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "open-deployment-menu-bar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // DeploymentCore is compiled into each app directly; the iOS app and widget pick it up from project.yml.
        .executableTarget(
            name: "open-deployment-menu-bar",
            path: "Sources",
            sources: ["open-deployment-menu-bar", "DeploymentCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "open-deployment-menu-barTests",
            dependencies: ["open-deployment-menu-bar"]
        ),
    ]
)
