// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mima",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "mima", targets: ["mima"]),
        .library(name: "MimaLib", targets: ["MimaLib"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "MimaLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .executableTarget(
            name: "mima",
            dependencies: ["MimaLib"]
        ),
        .testTarget(
            name: "mimaTests",
            dependencies: ["MimaLib"]
        ),
    ]
)
