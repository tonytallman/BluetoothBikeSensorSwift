# BluetoothBikeSensorSwift

A Swift package that scans for, connects to, and reads Bluetooth CSCS (Cycling Speed and Cadence Service) sensors. Includes an iOS SwiftUI sample app.

**Status:** Phase 4 — live measurements. `ConnectedSensor` exposes optional `speed` and `cadence` streams from CSC Measurement notifications. Set `wheelCircumference` for speed calculation; streams finish on disconnect. Sample app UI is still placeholder (Phase 5).

## Requirements

- iOS 17+
- Swift 6.0+
- Xcode 16+

## Project layout

```
BluetoothBikeSensorSwift/          # Swift package (library)
  Package.swift
  Sources/BluetoothBikeSensorSwift/
  Tests/BluetoothBikeSensorSwiftTests/
SampleApp/                         # iOS SwiftUI sample app
  SampleApp.xcodeproj
  SampleApp/
```

## Building

### Library

The library targets iOS (and macOS for local test runs). Build for the iOS simulator:

```bash
swift build \
  -Xswiftc -sdk -Xswiftc "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -Xswiftc -target -Xswiftc "$(uname -m)-apple-ios17.0-simulator"
```

### Tests

Unit tests inject package-visible test doubles and run on the macOS host without Bluetooth hardware:

```bash
swift test
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

## Public API

- `Scanner()` — client initializer; wires production dependencies internally
- `Scanner.scan()` — returns `AsyncStream<DiscoveredSensor>` filtered to CSC service (`0x1816`); cancel the stream to stop scanning
- `DiscoveredSensor` — discovery metadata (`id`, `name`, `manufacturer`, `hasSpeed`, `hasCadence`)
- `DiscoveredSensor.connect()` — connects, discovers CSC service/characteristics, enables measurement notifications; throws `ConnectError`
- `ConnectedSensor` — `wheelCircumference` (client-managed, default 2.105 m); optional `speed` / `cadence` streams; `disconnect() async throws -> DiscoveredSensor`
- `Speed` — typealias for `Measurement<UnitSpeed>`
- `Cadence` — typealias for `Measurement<UnitFrequency>`; use `UnitFrequency.revolutionsPerMinute` for cadence
- `ConnectError` — `notPoweredOn`, `timeout`, `failed`, `peripheralNotFound`, `serviceDiscoveryFailed`
- `DisconnectError` — `failed`, `alreadyDisconnected`

Test-only dependency injection (`BluetoothCentral`, `FakeBluetoothCentral`, `Scanner.init(central:)`) is `package`-visible within the Swift package, not part of the public client API.

See [project.md](project.md) for the full design and [plan.md](plan.md) for the implementation roadmap.
