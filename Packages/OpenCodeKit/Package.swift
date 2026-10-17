// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenCodeKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "OpenCodeTransport", targets: ["OpenCodeTransport"]),
        .library(name: "OpenCodeDomain", targets: ["OpenCodeDomain"]),
        .library(name: "OpenCodeStorage", targets: ["OpenCodeStorage"]),
    ],
    dependencies: [
        // I9: pin exact resolved dependencies (docs/implementation-defaults.md).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "OpenCodeTransport"),
        .target(name: "OpenCodeDomain", dependencies: ["OpenCodeTransport"]),
        .target(
            name: "OpenCodeStorage",
            dependencies: [
                "OpenCodeDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "OpenCodeKitTests",
            dependencies: ["OpenCodeTransport", "OpenCodeDomain", "OpenCodeStorage"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
