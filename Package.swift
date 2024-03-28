// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Confidence",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ConfidenceProvider",
            targets: ["ConfidenceProvider"]),
        .library(
            name: "Confidence",
            targets: ["Confidence"])
    ],
    dependencies: [
        .package(url: "git@github.com:open-feature/swift-sdk.git", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "Confidence",
            dependencies: [],
            plugins: []
        ),
        .target(
            name: "ConfidenceProvider",
            dependencies: [
                .product(name: "OpenFeature", package: "swift-sdk"),
                "Confidence"
            ],
            plugins: []
        ),
        .testTarget(
            name: "ConfidenceProviderTests",
            dependencies: [
                "ConfidenceProvider",
            ]
        )
    ]
)
