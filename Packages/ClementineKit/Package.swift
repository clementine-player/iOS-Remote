// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ClementineKit",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "ClementineKit", targets: ["ClementineKit"]),
        .library(name: "ClementineWatch", targets: ["ClementineWatch"]),
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
        // What the phone and the watch tell each other. Only Foundation, so the watch needn't
        // build the rest.
        .target(name: "ClementineWatch"),
        .testTarget(
            name: "ClementineKitTests",
            dependencies: ["ClementineKit", "ClementineWatch"]
        ),
    ]
)
