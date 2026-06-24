// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "padkey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "padkey", targets: ["padkey"])
    ],
    targets: [
        .executableTarget(
            name: "padkey",
            path: "Sources/padkey"
        ),
        .testTarget(
            name: "padkeyTests",
            dependencies: ["padkey"],
            path: "Tests/padkeyTests"
        )
    ]
)
