// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "BigDaddy",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "BigDaddy", targets: ["BigDaddy"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "BigDaddy",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "BigDaddy",
            exclude: ["Info.plist"]
        )
    ]
)
