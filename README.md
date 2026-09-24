# BluetoothBikeSensorSwift

A Swift package for Bluetooth CSCS (Cycling Speed and Cadence Service) with two library products:

- **`CSCClient`** scans for, connects to, and reads CSCS sensors.
- **`CSCServer`** advertises and serves CSCS as a peripheral, so your app can act as a speed and cadence sensor.

The iOS SwiftUI sample app uses `CSCClient` only.

## Requirements

- iOS 17+
- Swift 6.1+
- Xcode 16+

## Installation

Add the package to your Xcode project or `Package.swift`. Each product can be added on its own. The client library product was renamed from `BluetoothBikeSensorSwift` to **`CSCClient`** (breaking change for adopters).

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

## App configuration

### Usage description

Both products need `NSBluetoothAlwaysUsageDescription` in `Info.plist`. (`NSBluetoothPeripheralUsageDescription` applies only below iOS 13, so it is not needed at iOS 17+.) The permission prompt appears when `Scanner()` is created and when `Server.start()` runs.

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Your reason for using Bluetooth.</string>
```

### Background modes

To keep using Bluetooth in the background, add `UIBackgroundModes`:

- `bluetooth-central` for `CSCClient`. In Xcode: Signing & Capabilities → Background Modes → "Uses Bluetooth LE accessories".
- `bluetooth-peripheral` for `CSCServer`. In Xcode: Background Modes → "Acts as a Bluetooth LE accessory".

```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```

Background constraints (see Apple's "Core Bluetooth Background Processing for iOS Apps"):

- Background scans need a service filter. `Scanner` filters on `0x1816`. iOS coalesces repeated discoveries while in the background.
- Background advertising drops the local name and moves service UUIDs to the overflow area. Only iOS devices that explicitly scan for `0x1816` can find the device. Keep the app in the foreground if bike computers must discover it.
- The background mode wakes the app for Bluetooth events. It does not keep app timers running.
- Neither product implements Core Bluetooth state preservation and restoration.

### Denied access

If the user denies Bluetooth access, `Server.start()` throws `ServerError.notPoweredOn` and `Scanner.scan()` finishes empty. Check `CBManager.authorization` to decide whether to send the user to Settings.

See [`SampleApp/SampleApp/Info.plist`](SampleApp/SampleApp/Info.plist) for an example.

## CSCClient

### Scan and connect

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

Multiple sensors may be connected at once.

### Stop scanning

Cancel the task that iterates `scan()`:

```swift
let scanTask = Task {
    for await sensor in scanner.scan() {
        print("Found \(sensor.name ?? "sensor")")
    }
}

// Later:
scanTask.cancel()
```

If Bluetooth is not powered on within about 2 seconds, `scan()` finishes empty. On first launch, call `scan()` again after the user answers the permission prompt.

### Wheel size

Speed is derived from wheel revolutions and **client-managed wheel circumference** on `WheelRevolutions`. Set `wheel.wheelCircumference` before or during streaming; the default is 2.105 m (700×25C). The library does **not** read, write, or persist wheel size.

### Client API

- `Scanner()` — client initializer; wires production dependencies internally
- `Scanner.scan()` — returns `AsyncStream<DiscoveredSensor>` filtered to CSC service (`0x1816`); cancel the iterating task to stop scanning
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

### Client limitations

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

## CSCServer

### Build and start

```swift
import CSCServer

struct ResetWheelCount: SetCumulativeWheelRevolutions {
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
        // Store the new cumulative wheel count in your model.
    }
}

let (wheelRevolutions, wheelInput) = AsyncStream.makeStream(of: WheelRevolution.self)
let (crankRevolutions, crankInput) = AsyncStream.makeStream(of: CrankRevolution.self)

let server = Server
    .wheelRevolutions(wheelRevolutions, setCumulativeWheelRevolutions: ResetWheelCount())
    .crankRevolutions(crankRevolutions)
    .staticSensorLocation(.rearDropout)
    .build()

try await server.start() // publishes 0x1816; returns once advertising has started

// Event times are CSC wire units (1/1024 s). Samples are dropped until a central subscribes.
wheelInput.yield(WheelRevolution(cumulativeRevolutions: 1_234, lastEventTime: 2_048))
crankInput.yield(CrankRevolution(cumulativeRevolutions: 56, lastEventTime: 2_048))

await server.stop()
```

Revolution sources are any `AsyncSequence & Sendable` of `WheelRevolution` or `CrankRevolution`, including `AsyncStream`.

### Builder rules

- Entry points: `Server.wheelRevolutions(_:setCumulativeWheelRevolutions:)` and `Server.crankRevolutions(_:)`.
- Chain methods: `wheelRevolutions(_:setCumulativeWheelRevolutions:)`, `crankRevolutions(_:)`, `staticSensorLocation(_:)`, `multipleSensorLocations(_:)`, then `build()`.
- Static and multiple sensor locations are mutually exclusive; the type-state builder rejects both at compile time.
- Wheel data always requires a `SetCumulativeWheelRevolutions` delegate.
- Start Sensor Calibration is not supported.
- `Server` has no public initializer.

`build()` fixes the CSC Feature bits and characteristic inventory:

| Configuration | Feature bytes | Characteristics |
|---|---|---|
| Crank | `02 00` | Measurement, Feature |
| Crank + static | `02 00` | Measurement, Feature, Sensor Location (cached) |
| Wheel | `01 00` | Measurement, Feature, Control Point |
| Wheel + static | `01 00` | Measurement, Feature, Sensor Location (cached), Control Point |
| Wheel + crank | `03 00` | Measurement, Feature, Control Point |
| Wheel + crank + static | `03 00` | Measurement, Feature, Sensor Location (cached), Control Point |
| Crank + multiple | `06 00` | Measurement, Feature, Sensor Location (`nil`), Control Point |
| Wheel + multiple | `05 00` | Measurement, Feature, Sensor Location (`nil`), Control Point |
| Wheel + crank + multiple | `07 00` | Measurement, Feature, Sensor Location (`nil`), Control Point |

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

### Lifecycle

- `start()` returns once advertising has started and Bluetooth stayed powered on during startup. Cancelling the task awaiting `start()` rolls back partial startup and throws `CancellationError`.
- `stop()` is idempotent and returns after teardown: advertising stopped, the service removed, notifications ended, and any in-flight delegate call returned.
- Only one `Server` per process can be starting, running, or stopping at a time. Another `Server`'s `start()` throws `ServerError.alreadyStarted`.
- Keep a strong reference to a started server. Releasing it stops it in the background, and the slot is freed only after that teardown finishes, so `await server.stop()` before starting another server right away.
- `start()` after `stop()` is allowed. A single-pass `AsyncStream` source is terminated once `stop()` cancels its iteration; use a multi-pass sequence or build a new `Server` to publish again with the same stream. On multiple-location servers, the location served after restart is the last one `update(_:)` returned successfully.

### Bluetooth changes

`start()` throws `ServerError.notPoweredOn` if Bluetooth is powered off, unauthorized, or unsupported, or if it is lost before `start()` finishes. It waits while the state is unknown or resetting, for example during the permission prompt.

If Bluetooth leaves the powered-on state after `start()` returns, the server suspends: it drops all subscriptions and queued notifications, keeps pulling samples (which are dropped because nobody is subscribed), and stops advertising. When Bluetooth is powered on again, it republishes the same service and advertises again automatically. Centrals must reconnect and resubscribe. If republishing fails, the server stays suspended, without throwing, until Bluetooth turns off and on again. There is no public status for these transitions. An unauthorized state is reported as `ServerError.notPoweredOn`; check `CBManager.authorization` to tell the cases apart.

### Control point

Servers with wheel data or multiple sensor locations include SC Control Point (`0x2A55`) and handle three procedures:

- Set Cumulative Value (`0x01`) calls your `SetCumulativeWheelRevolutions` delegate.
- Update Sensor Location (`0x03`) calls your `MultipleSensorLocationsDelegate`.
- Request Supported Sensor Locations (`0x04`) answers from the list captured at `build()`.

One procedure runs at a time. A procedure has 30 seconds from the accepted write until its indication is handed to the system. After that, the server stops the procedure and sends no indication. An indication already handed to the system cannot be recalled. Delegates must honor task cancellation; `stop()` and the timeout both cancel an in-flight call.

The server cancels a call still running 30 seconds after the write was accepted. A call that returns successfully after that has still been applied, and no indication is sent. The peer may retry, so make your implementation safe to call again.

### Feature bits

CSC Feature and the characteristic inventory are fixed at `build()` for the life of the `Server`, including across `stop()`/`start()` and Bluetooth recovery. To change features, stop and build a new `Server`. A new `Server` publishes a new GATT database; centrals may need to reconnect and rediscover.

### Server API

- `Server.wheelRevolutions(_:setCumulativeWheelRevolutions:)` — wheel entry point; set-cumulative delegate is required
- `Server.crankRevolutions(_:)` — crank entry point
- `wheelRevolutions(_:setCumulativeWheelRevolutions:)`, `crankRevolutions(_:)`, `staticSensorLocation(_:)`, `multipleSensorLocations(_:)` — chain methods
- `build()` — returns a configured `Server` (no public `Server` initializer)
- `Server.start()` / `Server.stop()` — publish and advertise the CSC service, and tear it down
- `ServerError` — `unsupportedConfiguration` (reserved), `alreadyStarted` (this or another `Server` is live), `notPoweredOn` (unavailable, powered off, unauthorized, or unsupported during startup, or lost before `start()` finished), `publishFailed`, `advertisingFailed`
- `WheelRevolution`, `CrankRevolution` — CSC Measurement wire units for server sequences
- `SensorLocationKind` — GATT assigned numbers 0...16 for the builder
- `SetCumulativeWheelRevolutions` — called for Set Cumulative Value
- `MultipleSensorLocationsDelegate` — `supported`, `current`, and `update(_:)` for Update Sensor Location on multiple-location servers

`CSCWire` holds shared CSCS wire codecs as an internal package target. It is not a library product. The peripheral seam stays package-visible inside the package.

### Server limitations

- Advertises only the CSC service UUID; no local name.
- No MTU negotiation, so Request Supported Sensor Locations fits at most 17 locations.
- A peripheral cannot disconnect a central.
- No Core Bluetooth state preservation and restoration.
- Background advertising limits apply (see [Background modes](#background-modes)).

## Project layout

```
BluetoothBikeSensorSwift/          # Swift package (library products: CSCClient, CSCServer)
  Package.swift                    # open this in Xcode to run unit tests
  Sources/CSCClient/
  Sources/CSCServer/               # library product; builder, `Server`, peripheral seam
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

See [project.md](project.md) for the full design.
