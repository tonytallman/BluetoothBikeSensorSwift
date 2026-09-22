// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "BluetoothBikeSensorSwift",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CSCClient",
            targets: ["CSCClient"],
        ),
        .library(
            name: "CSCServer",
            targets: ["CSCServer"],
        ),
    ],
    targets: [
        .target(name: "CSCWire"),
        .target(
            name: "CSCClient",
            dependencies: ["CSCWire"],
        ),
        .target(
            name: "CSCServer",
            dependencies: ["CSCWire"],
        ),
        .testTarget(
            name: "CSCWireTests",
            dependencies: ["CSCWire"],
        ),
        .testTarget(
            name: "CSCClientTests",
            dependencies: [
                "CSCClient",
                "CSCWire",
            ],
        ),
        .testTarget(
            name: "CSCServerTests",
            dependencies: [
                "CSCServer",
                "CSCWire",
            ],
        ),
    ]
)
