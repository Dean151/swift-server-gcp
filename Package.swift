// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-server-gcp",
    platforms: [
        // macOS 13 is the floor for the modern Foundation surface we
        // depend on (Date.ISO8601FormatStyle, FileHandle.write(contentsOf:)).
        // Linux is unaffected by this declaration.
        .macOS(.v13),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "GoogleCloudPlatform",
            targets: ["GoogleCloudPlatform"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "GoogleCloudPlatform",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
        .testTarget(
            name: "GoogleCloudPlatformTests",
            dependencies: ["GoogleCloudPlatform"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
