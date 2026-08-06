# BluetoothBikeSensorSwift

A Swift package that scans for, connects to, and reads Bluetooth CSCS (Cycling Speed and Cadence Service) sensors. Includes an iOS SwiftUI sample app.

**Status:** Phase 5 — sample app. The iOS SwiftUI app scans for CSC sensors, connects to one or more devices, shows live speed (km/h) and cadence (rpm), and lets you configure wheel circumference from a settings sheet. Library Phases 1–4 are complete.

## Requirements

- iOS 17+
- Swift 6.0+
- Xcode 16+

## Project layout

```
BluetoothBikeSensorSwift/          # Swift package (library)
  Package.swift                    # open this in Xcode to run unit tests
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

In Xcode:

1. Open `Package.swift` (File → Open → select the package root or `Package.swift`).
2. Select the **BluetoothBikeSensorSwift** scheme.
3. Choose a **My Mac** destination (package tests run on macOS).
4. Product → Test (⌘U).

Do not use `SampleApp.xcodeproj` for unit tests — that project only builds the sample app. Package tests live in the Swift package scheme.

### Sample app

Open `SampleApp/SampleApp.xcodeproj` in Xcode and run the **SampleApp** scheme on an iOS simulator or device.

Or from the command line:

```bash
xcodebuild \
  -project SampleApp/SampleApp.xcodeproj \
  -scheme SampleApp \
  -destination 'generic/platform=iOS Simulator' \
  build
```

The sample app provides a single scan list:

1. Tap **Scan** to discover nearby CSC sensors (requires a device with Bluetooth; the simulator cannot scan).
2. Tap **Connect** on a row to connect and subscribe to live measurements.
3. Speed is shown in km/h; cadence in rpm. Unsupported metrics show "—".
4. Tap the gear icon to set wheel circumference (meters); changes apply to all connected sensors.
5. Tap **Disconnect** to release a sensor. Connect/disconnect failures show an alert.

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
