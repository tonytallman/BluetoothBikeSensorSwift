# BluetoothBikeSensorSwift

A Swift package that scans for, connects to, and reads Bluetooth CSCS (Cycling Speed and Cadence Service) sensors. Includes an iOS SwiftUI sample app.

**Status:** Phase 6 — hardened and documented. The library and sample app are complete through CSC scan, connect, live measurements, and disconnect.

## Requirements

- iOS 17+
- Swift 6.0+
- Xcode 16+

## Installation

Add the package to your Xcode project or `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/tonytallman/BluetoothBikeSensorSwift.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "BluetoothBikeSensorSwift", package: "BluetoothBikeSensorSwift"),
        ],
    ),
]
```

For local development, use a path dependency:

```swift
.package(path: "../BluetoothBikeSensorSwift"),
```

## Usage

```swift
import BluetoothBikeSensorSwift

let scanner = Scanner()

for await sensor in scanner.scan() {
    do {
        let connected = try await sensor.connect()
        connected.wheelCircumference = Measurement(value: 2.105, unit: .meters)

        if let speedStream = connected.speed {
            Task {
                for await speed in speedStream {
                    let kmh = speed.converted(to: .kilometersPerHour)
                    print("Speed: \(kmh)")
                }
            }
        }

        if let cadenceStream = connected.cadence {
            Task {
                for await cadence in cadenceStream {
                    let rpm = cadence.converted(to: .revolutionsPerMinute)
                    print("Cadence: \(rpm)")
                }
            }
        }

        // When finished:
        let rediscovered = try await connected.disconnect()
        _ = rediscovered
    } catch {
        print("Connect failed: \(error)")
    }
}
```

Cancel the scan stream to stop scanning. Multiple sensors may be connected at once.

## Wheel size

Speed is derived from wheel revolutions and **client-managed wheel circumference**. Set `ConnectedSensor.wheelCircumference` before or during streaming; the default is 2.105 m (700×25C). The library does **not** read, write, or persist wheel size.

## Permissions

Apps must include a Bluetooth usage description in `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Your reason for using Bluetooth.</string>
```

See [`SampleApp/SampleApp/Info.plist`](SampleApp/SampleApp/Info.plist) for an example.

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

CI runs the same command on macOS for pushes and pull requests to `main`.

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
3. Speed is shown in km/h; cadence in rpm. Unsupported metrics are hidden after connect.
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

Public types include DocC-style `///` comments in source. Test-only dependency injection (`BluetoothCentral`, `FakeBluetoothCentral`, `Scanner.init(central:)`) is `package`-visible within the Swift package, not part of the public client API.

## Limitations

- **Multi-connection:** Multiple sensors may be connected simultaneously.
- **Discovery metadata:** `name` and `manufacturer` are best-effort from advertisement data and may be absent.
- **Capability flags:** `hasSpeed` and `hasCadence` on `DiscoveredSensor` are best-effort at discovery time. After connect, rely on non-`nil` `speed` / `cadence` streams for supported metrics.
- **Unexpected disconnect:** If the link drops, measurement streams finish without throwing `DisconnectError`. Only an explicit `disconnect()` call that fails throws.
- **Scan and Bluetooth state:** If Bluetooth is off when scanning starts, the scan stream finishes empty. Toggling Bluetooth off mid-scan does not automatically stop an active scan stream; cancel the stream to stop scanning.
- **Simulator:** The iOS Simulator cannot scan for Bluetooth peripherals; use a physical device for end-to-end testing.
- **Concurrency:** The library is not MainActor-bound. Hop to the main actor in UI code when updating views.

See [project.md](project.md) for the full design and [plan.md](plan.md) for the implementation roadmap.
