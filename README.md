# BluetoothBikeSensorSwift

A Swift package that scans for, connects to, and reads Bluetooth CSCS (Cycling Speed and Cadence Service) sensors. Includes an iOS SwiftUI sample app.

## Requirements

- iOS 17+
- Swift 6.1+
- Xcode 16+

## Installation

Add the package to your Xcode project or `Package.swift`. The library product was renamed from `BluetoothBikeSensorSwift` to **`CSCClient`** (breaking change for adopters).

```swift
dependencies: [
    .package(url: "https://github.com/tonytallman/BluetoothBikeSensorSwift.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "CSCClient", package: "BluetoothBikeSensorSwift"),
            .product(name: "CSCServer", package: "BluetoothBikeSensorSwift"),
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
import CSCClient

let scanner = Scanner()

for await sensor in scanner.scan() {
    do {
        let connected = try await sensor.connect()

        switch connected.revolutions {
        case let .wheel(wheel):
            wheel.wheelCircumference = Measurement(value: 2.105, unit: .meters)
            for await speed in await wheel.speed {
                let kmh = speed.converted(to: .kilometersPerHour)
                print("Speed: \(kmh)")
            }
        case let .crank(crank):
            for await cadence in await crank.cadence {
                let rpm = cadence.converted(to: .revolutionsPerMinute)
                print("Cadence: \(rpm)")
            }
        case let .wheelAndCrank(wheel, crank):
            wheel.wheelCircumference = Measurement(value: 2.105, unit: .meters)
            let speedTask = Task {
                for await speed in await wheel.speed {
                    print("Speed: \(speed.converted(to: .kilometersPerHour))")
                }
            }
            let cadenceTask = Task {
                for await cadence in await crank.cadence {
                    print("Cadence: \(cadence.converted(to: .revolutionsPerMinute))")
                }
            }
            _ = await (speedTask.value, cadenceTask.value)
        }

        switch connected.location {
        case .unavailable:
            break
        case let .fixed(location):
            print("Location: \(location.displayName)")
        case let .multiple(locations):
            print("Current location: \(locations.current.displayName)")
            if let rearDropout = locations.supported.first(where: { $0.kind == .rearDropout }) {
                try await locations.update(rearDropout)
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

### CSC server builder

`CSCServer` provides a type-state builder and a `Server` runtime. `build()` records CSCS feature bits, the GATT characteristic inventory, revolution sequences, and delegates. **Phase 3** adds `start()` / `stop()` for crank-only and crank-plus-static-location configurations: the server publishes CSCS (`0x1816`), serves feature and static-location reads, and notifies crank measurements. Wheel and multiple-location configurations still throw `ServerError.unsupportedConfiguration` until later phases.

```swift
import CSCServer

// Crank only
let crankOnly = Server.crankRevolutions(crankStream).build()

// Crank + static location
let crankStatic = Server.crankRevolutions(crankStream)
    .staticSensorLocation(.leftCrank)
    .build()

// Wheel only (set-cumulative delegate required)
let wheelOnly = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .build()

// Wheel + static location
let wheelStatic = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .staticSensorLocation(.rearDropout)
    .build()

// Wheel + crank
let wheelCrank = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .crankRevolutions(crankStream)
    .build()

// Wheel + crank + static location
let wheelCrankStatic = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .crankRevolutions(crankStream)
    .staticSensorLocation(.rearWheel)
    .build()

// Crank + multiple locations
let crankMultiple = Server.crankRevolutions(crankStream)
    .multipleSensorLocations(locationsDelegate)
    .build()

// Wheel + multiple locations
let wheelMultiple = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .multipleSensorLocations(locationsDelegate)
    .build()

// Wheel + crank + multiple locations
let wheelCrankMultiple = Server.wheelRevolutions(wheelStream, setCumulativeWheelRevolutions: cumulative)
    .crankRevolutions(crankStream)
    .multipleSensorLocations(locationsDelegate)
    .build()
```

`Server` has no public initializer. Call `start()` after `build()` on supported crank configurations; call `stop()` to tear down advertising and the published service.

```swift
let server = Server.crankRevolutions(crankStream)
    .staticSensorLocation(.leftCrank)
    .build()

Task {
    do {
        try await server.start() // advertises 0x1816 until stop() or cancellation
    } catch {
        // ServerError: unsupportedConfiguration, alreadyStarted,
        // bluetoothUnavailable, publishFailed, advertisingFailed, revolutionSequenceFailed
    }
}

// later:
await server.stop()
```

## Wheel size

Speed is derived from wheel revolutions and **client-managed wheel circumference** on ``WheelRevolutions``. Set `wheel.wheelCircumference` before or during streaming; the default is 2.105 m (700×25C). The library does **not** read, write, or persist wheel size.

## Permissions

Apps must include a Bluetooth usage description in `Info.plist`:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Your reason for using Bluetooth.</string>
```

See [`SampleApp/SampleApp/Info.plist`](SampleApp/SampleApp/Info.plist) for an example.

## Project layout

```
BluetoothBikeSensorSwift/          # Swift package (library products: CSCClient, CSCServer)
  Package.swift                    # open this in Xcode to run unit tests
  Sources/CSCClient/
  Sources/CSCServer/               # library product; peripheral seam + Phase 2 builder
  Sources/CSCWire/                 # internal target; not a library product
  Tests/CSCClientTests/
  Tests/CSCServerTests/
  Tests/CSCWireTests/
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
2. Select the **CSCClient** scheme.
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
3. Speed is shown in km/h; cadence in rpm. Fixed sensor locations show a label; sensors with multiple locations offer an update control. Unsupported metrics are hidden after connect.
4. Tap the gear icon to set wheel circumference (meters); changes apply to all connected sensors.
5. Tap **Disconnect** to release a sensor. Connect/disconnect failures show an alert.

## Public API

- `Scanner()` — client initializer; wires production dependencies internally
- `Scanner.scan()` — returns `AsyncStream<DiscoveredSensor>` filtered to CSC service (`0x1816`); cancel the stream to stop scanning
- `DiscoveredSensor` — discovery metadata (`id`, `name`, `manufacturer`, `hasSpeed`, `hasCadence`); capability flags are best-effort hints only
- `DiscoveredSensor.connect()` — connects, reads CSC Feature (`0x2A5C`), resolves wheel/crank/location support, enables notifications; throws `ConnectError`
- `ConnectedSensor` — `revolutions: RevolutionData` (`.wheel` / `.crank` / `.wheelAndCrank`) and `location: LocationSupport` (`.unavailable` / `.fixed` / `.multiple`); `disconnect() async throws -> DiscoveredSensor`
- `WheelRevolutions` — client-managed `wheelCircumference` (default 2.105 m); `speed`, `wheelSamples`, and `setCumulativeRevolutions(_:)` (throws `ControlPointError.controlPointUnavailable` when the sensor did not expose SC Control Point)
- `CrankRevolutions` — `cadence` and `crankSamples`
- `SensorLocation` — peripheral-originated GATT location token with `kind` (for logic) and `displayName` (for UI)
- `MultipleSensorLocations` — `supported`, `current`, and `update(_:)` for sensors with multiple location support
- `ControlPointError` — control-point procedure failures (`unsupportedLocation`, `controlPointUnavailable`, `procedureInProgress`, `timedOut`, and server response mappings)
- `WheelSample` — `deltaDistance` (`Measurement<UnitLength>`) and `deltaTime` (`Measurement<UnitDuration>`) between CSC wheel events
- `CrankSample` — `deltaRevolutions` (`Int`) and `deltaTime` (`Measurement<UnitDuration>`) between CSC crank events
- `Speed` — typealias for `Measurement<UnitSpeed>`
- `Cadence` — typealias for `Measurement<UnitFrequency>`; use `UnitFrequency.revolutionsPerMinute` for cadence
- `ConnectError` — `notPoweredOn`, `timeout`, `failed`, `peripheralNotFound`, `serviceDiscoveryFailed`
- `DisconnectError` — `failed`, `alreadyDisconnected`

Public types include DocC-style `///` comments in source. Test-only dependency injection (`BluetoothCentral`, `FakeBluetoothCentral`, `Scanner.init(central:)`) is `package`-visible within the Swift package, not part of the public client API.

`CSCWire` holds shared CSCS wire codecs as an internal package target. It is not a library product.

`CSCServer` is a library product: configuration builder, `Server`, and (for crank-only / crank-plus-static location) `start()` / `stop()`. The peripheral seam stays package-visible for unit tests.

**CSCServer builder surface:**

- `Server.wheelRevolutions(_:setCumulativeWheelRevolutions:)` — wheel entry point; set-cumulative delegate is required
- `Server.crankRevolutions(_:)` — crank entry point
- `wheelRevolutions(_:setCumulativeWheelRevolutions:)`, `crankRevolutions(_:)`, `staticSensorLocation(_:)`, `multipleSensorLocations(_:)` — chain methods
- `build()` — returns a configured `Server` (no public `Server` initializer)
- `start()` / `stop()` — publish and advertise CSCS for crank-only and crank-plus-static location; unsupported configurations throw `ServerError.unsupportedConfiguration`
- `ServerError` — session failures (`unsupportedConfiguration`, `alreadyStarted`, `bluetoothUnavailable`, `publishFailed`, `advertisingFailed`, `revolutionSequenceFailed`)
- `WheelRevolution`, `CrankRevolution` — CSC Measurement wire units for server sequences
- `SensorLocationKind` — GATT assigned numbers 0...16 for the builder
- `SetCumulativeWheelRevolutions`, `MultipleSensorLocationsDelegate` — control-point delegates stored by `build()` and serviced in later phases

## Limitations

- **Multi-connection:** Multiple sensors may be connected simultaneously.
- **Discovery metadata:** `name` and `manufacturer` are best-effort from advertisement data and may be absent.
- **Capability flags:** `hasSpeed` and `hasCadence` on `DiscoveredSensor` are best-effort at discovery time. After connect, rely on `ConnectedSensor.revolutions` and the streams on `WheelRevolutions` / `CrankRevolutions`.
- **Feature-driven support:** Wheel, crank, and location support come from CSC Feature (`0x2A5C`) at connect time. Advertisement flags are not used as a fallback.
- **CSC event-time wrap (64 s):** last-event time is uint16 at 1/1024 s and wraps every 64 seconds. If the sensor is silent for ~65 s, wrapping Δt can compute to ~1 s. One revolution over that wrong Δt is ~2.1 m/s, which passes the implausible-delta guard, so a sample is emitted with a wrong Δt. Downstream accumulators will add that Δt to total time. This is inherent to the protocol; this library does not reconstruct wall-clock intervals as `deltaTime`.
- **Zero-distance / zero-revolution samples:** when Δt > 0 but revolutions did not change, the library emits a sample with zero quantity (0 m/s / 0 rpm). Spec-compliant firmware rarely advances event time without a revolution; non-compliant firmware can accrue moving time in downstream accumulators until autopause gates it.
- **Unexpected disconnect:** If the link drops, measurement streams finish without throwing `DisconnectError`. Only an explicit `disconnect()` call that fails throws.
- **Scan and Bluetooth state:** If Bluetooth is off when scanning starts, the scan stream finishes empty. Toggling Bluetooth off mid-scan does not automatically stop an active scan stream; cancel the stream to stop scanning.
- **Simulator:** The iOS Simulator cannot scan for Bluetooth peripherals; use a physical device for end-to-end testing.
- **Concurrency:** The library is not MainActor-bound. Hop to the main actor in UI code when updating views.

See [project.md](project.md) for the full design.
