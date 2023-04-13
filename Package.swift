// swift-tools-version: 5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ConfidenceProvider",
    platforms: [
        .iOS(.v14),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "ConfidenceProvider",
            targets: ["ConfidenceProvider"])
    ],
    dependencies: [
        .package(url: "git@github.com:spotify/openfeature-swift-sdk.git", from: "0.2.1"),
    ],
    targets: [
        .target(
            name: "ConfidenceProvider",
            dependencies: [
                .product(name: "OpenFeature", package: "openfeature-swift-sdk"),
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
