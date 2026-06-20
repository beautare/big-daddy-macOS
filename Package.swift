// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "BigDaddy",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "BigDaddy", targets: ["BigDaddy"])
    ],
    targets: [
        .executableTarget(
            name: "BigDaddy",
            path: "BigDaddy",
            exclude: ["Info.plist"]
        )
    ]
)
