// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BluetoothBikeSensorSwift",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "BluetoothBikeSensorSwift",
            targets: ["BluetoothBikeSensorSwift"]
        ),
    ],
    targets: [
        .target(
            name: "BluetoothBikeSensorSwift"
        ),
    ]
)
