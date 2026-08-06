# BluetoothBikeSensorSwift

A Swift package that scans for, connects to, and reads Bluetooth CSCS (Cycling Speed and Cadence Service) sensors. Includes an iOS SwiftUI sample app.

**Status:** Phase 0 — package skeleton and public API stubs. Bluetooth behavior is not implemented yet.

## Requirements

- iOS 17+
- Swift 6.0+
- Xcode 16+

## Project layout

```
BluetoothBikeSensorSwift/          # Swift package (library)
  Package.swift
  Sources/BluetoothBikeSensorSwift/
SampleApp/                         # iOS SwiftUI sample app
  SampleApp.xcodeproj
  SampleApp/
```

## Building

### Library

The library targets iOS only. Build for the iOS simulator:

```bash
swift build \
  -Xswiftc -sdk -Xswiftc "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -Xswiftc -target -Xswiftc "$(uname -m)-apple-ios17.0-simulator"
```

### Sample app

Open `SampleApp/SampleApp.xcodeproj` in Xcode and run on an iOS simulator or device.

Or from the command line:

```bash
xcodebuild \
  -project SampleApp/SampleApp.xcodeproj \
  -scheme SampleApp \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Public API (stubs)

- `Scanner` — `scan() -> AsyncStream<DiscoveredSensor>`
- `DiscoveredSensor` — discovery metadata; `connect() async throws -> ConnectedSensor`
- `ConnectedSensor` — optional `speed` / `cadence` streams; `disconnect() async throws -> DiscoveredSensor`
- `Speed` — typealias for `Measurement<UnitSpeed>`
- `Cadence` — typealias for `Measurement<UnitFrequency>`; use `UnitFrequency.revolutionsPerMinute` for cadence
- `ConnectError`, `DisconnectError` — stub error enums

See [project.md](project.md) for the full design and [plan.md](plan.md) for the implementation roadmap.
