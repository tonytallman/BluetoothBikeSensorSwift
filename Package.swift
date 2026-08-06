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
            name: "BluetoothBikeSensorSwift",
            targets: ["BluetoothBikeSensorSwift"],
        ),
    ],
    targets: [
        .target(
            name: "BluetoothBikeSensorSwift",
        ),
        .testTarget(
            name: "BluetoothBikeSensorSwiftTests",
            dependencies: ["BluetoothBikeSensorSwift"],
        ),
    ]
)
