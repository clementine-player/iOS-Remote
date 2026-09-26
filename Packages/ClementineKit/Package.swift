// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClementineKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ClementineKit", targets: ["ClementineKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "ClementineKit",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "ClementineKitTests",
            dependencies: ["ClementineKit"]
        ),
    ]
)
