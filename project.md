# BluetoothBikeSensorSwift

## Summary

BluetoothBikeSensorSwift is a Swift package that scans for, connects to, and reads Bluetooth CSCS sensors, and can advertise as a CSCS peripheral. The Swift package name remains `BluetoothBikeSensorSwift`. Library products are **`CSCClient`** and **`CSCServer`**. `CSCWire` is an internal target, not a product. It includes the library, an iOS client sample app, and an iOS server sample app. It uses SOLID principles and any other best practices as appropriate.

## Decisions

- **`CSCWire` holds shared CSCS wire codecs** — measurement, feature, location, and control-point encode/decode live in an internal package target; `CSCWire` is not a library product.

- **`Scanner` is instantiable** with dependencies passed through its initializer (not a singleton).
- **`DiscoveredSensor` and `ConnectedSensor` have internal initializers only** — no public `CBPeripheral` initializers.
- **Wheel size is client-managed** — the client supplies wheel circumference (or equivalent) for speed calculation; the library does not read, write, or persist wheel size.
- **Sample app is iOS-only**, built with SwiftUI.
- **Sample app uses a single Scan list screen** — no separate sensor detail screen; row content is driven by a State Pattern for discovered vs connected states.
- **`Speed` and `Cadence` are Foundation `Measurement` typealiases** — `Speed` is `Measurement<UnitSpeed>`; `Cadence` is `Measurement<UnitFrequency>`. The library provides `UnitFrequency.revolutionsPerMinute` (`"rpm"`) for cadence values.
- **Missing SC Control Point does not fail wheel or wheel-and-crank `connect()` when the multiple-locations bit is clear** — Set Cumulative Value still requires the control point and throws `ControlPointError.controlPointUnavailable`. Multiple-locations connect still fails when the control point is absent, because connect runs Request Supported Sensor Locations.
- **`SensorLocation` is not publicly constructible** — clients obtain tokens from the peripheral and compare via `SensorLocation.Kind`. The server builder takes `SensorLocationKind` (GATT assigned numbers 0...16). That enum has no `reserved` case and no `displayName`.
- **Start Sensor Calibration (`0x02`) is not supported** — the client does not expose this control-point procedure.

### CSC Server

- **`CSCServer` is a library product.** `Server` is built from a type-state builder, then `start()` publishes the CSC GATT service and advertises `0x1816`. `CSCClient` does not depend on `CSCServer`.
- **Per-instance lifecycle.** Each `Server` owns `ServerLifecycle` (`idle`, `starting`, `running`, `stopping`). A second `start()` on the same instance throws `.alreadyStarted`; separate instances may run concurrently. `deinit` schedules `stop()` in the background.
- **`start()` / `stop()`.** `start()` waits for Bluetooth powered-on (no timeout through `.unknown`), adds the service, advertises service UUIDs, then starts the outbound pump and revolution loops. Partial startup rolls back on failure or cancellation. `stop()` is idempotent and tears down advertising, the service, and notifications.
- **Configuration at `build()`.** Wheel and/or crank `AsyncSequence` sources, optional static or multiple sensor locations, and delegates. Feature bits and characteristics are fixed for the life of the `Server`. SC Control Point is included when wheel data or multiple locations are configured.
- **Measurement path.** One outbound pump is the only `updateValue` caller. Samples with no subscribers are dropped. Stale wheel-generation payloads are discarded. Bluetooth loss suspends the session (clears subscribers, keeps caches and served location); recovery republishes when power returns.
- **Control point.** One procedure at a time with a 30-second injected timeout. Indications share the outbound pump with measurements. Set Cumulative Value calls the wheel delegate; multiple-location procedures use snapshotted supported locations and a served byte on `ServerLifecycle`.
- **Reads and writes.** Cached reads return offset slices. Dynamic sensor location and control-point rules follow CSCS and the builder inventory. The fake peripheral does not answer from cached values.
- **`BluetoothPeripheral` seam.** `CoreBluetoothPeripheral` for production; `FakeBluetoothPeripheral` for tests. Ordered `events` stream; `stateUpdates` for startup power wait only.
- **Public API.** ``Server/measurementSubscriberCount`` is the connection signal (0 while stopped, starting, or radio-suspended). No public Bluetooth power API; unauthorized maps to `.notPoweredOn`. Tests use `package` `start(peripheral:clock:)` and `isRadioSuspended`.
- **Async sources.** The builder accepts any `AsyncSequence & Sendable`; `AnyAsyncSequence` boxes iterators consumed from one task per source.

### Server sample app (Phase 7)

- **Separate Xcode project** `SampleServerApp/SampleServerApp.xcodeproj` depends only on the **`CSCServer`** product; the client sample is unchanged.
- **Fresh server per Start** — each Start builds a new `Server`, new `AsyncStream` sources, and new control-point delegates (including a new `SensorLocationsHandler` snapshot).
- **Simulation** — 1 s tick, revolution event times on an active timeline that pauses in the background, yield-only stream sources (no await on emit acceptance).
- **Server sample connection state (Phase 7).** Connection state is the subscribed-central count from ``Server/measurementSubscriberCount`` (0 while waiting for a client). Advertising is shown as the app's lifecycle phase combined with Bluetooth state. The control-point activity log still shows Set Cumulative Value and Update Sensor Location when a client writes the control point.
- **View models** — the server sample uses the protocol-based SwiftUI view-model pattern; the client sample predates it.

## Detailed Design

### Library

#### Scanner

- The `Scanner` type is instantiable (not singleton) in order to accept dependencies in the initializer.
- A function `scan()` on `Scanner` returns an `AsyncSequence` of `DiscoveredSensor`s.

#### DiscoveredSensor

- Has an internal initializer and therefore instances must be obtained from `Scanner.scan()`.
- Contains useful device information.
    - id (universally unique)
    - name
    - manufacturer
    - hasSpeed: Bool (if possible)
    - hasCadence: Bool (if possible)
- Has a single function `connect()` returning `async` `ConnectedSensor`, throwing `ConnectError`.

#### ConnectedSensor

- Has an internal initializer and therefore instances must be obtained from `DiscoveredSensor.connect()`.
- Has `revolutions: RevolutionData`:
    - `.wheel(WheelRevolutions)` — wheel speed and delta-sample streams
    - `.crank(CrankRevolutions)` — cadence and delta-sample streams
    - `.wheelAndCrank(WheelRevolutions, CrankRevolutions)` — both families
- Has `location: LocationSupport`:
    - `.unavailable` — no Sensor Location characteristic or unsupported configuration
    - `.fixed(SensorLocation)` — fixed location read from Sensor Location (`0x2A5D`)
    - `.multiple(MultipleSensorLocations)` — supported locations and `update(_:)` via SC Control Point
- Wheel/crank/location support is resolved from CSC Feature (`0x2A5C`) at connect time; advertisement flags are not used as a fallback.
- Wheel or wheel-and-crank connect succeeds when SC Control Point (`0x2A55`) is missing and the multiple-locations bit is clear. Measurement notifications are enabled; control-point notifications stay off. Multiple-locations connect still fails with `ConnectError.serviceDiscoveryFailed(reason: "SC Control Point characteristic missing")` when `0x2A55` is absent.
- Has a single function `disconnect()` returning `async` `DiscoveredSensor`, throwing `DisconnectError`.

#### WheelRevolutions

- Client-managed `wheelCircumference` (default 2.105 m); used for speed and wheel delta distance.
- `speed: AsyncStream<Speed>` and `wheelSamples: AsyncStream<WheelSample>`.
- `setCumulativeRevolutions(_:)` writes Set Cumulative Value (`0x01`) via SC Control Point and throws `ControlPointError.controlPointUnavailable` when the control point was not discovered.

#### CrankRevolutions

- `cadence: AsyncStream<Cadence>` and `crankSamples: AsyncStream<CrankSample>`.

#### SensorLocation

- Not publicly constructible; obtained from `LocationSupport` on a connected sensor.
- `kind: SensorLocation.Kind` — standard GATT identity for comparisons and selection.
- `displayName` — human-readable label for UI.

#### Measurement types

- `Speed` — `Measurement<UnitSpeed>` (e.g. meters per second, kilometers per hour).
- `Cadence` — `Measurement<UnitFrequency>` using `UnitFrequency.revolutionsPerMinute`.
- `UnitFrequency.revolutionsPerMinute` — library extension; coefficient `1/60` vs hertz (Foundation has no built-in RPM).

#### Open Questions

- Any other useful information to include with `DiscoveredSensor`?

**Resolved:** Wheel size is `WheelRevolutions.wheelCircumference` (client-managed, default 2.105 m). Clients that need to accumulate distance or cadence consume `wheelSamples` / `crankSamples` rather than raw CSC cumulative counters.

#### CSC Server (Phase 2–6)

Phase 2 adds a type-state builder on `Server` that records CSCS feature bits, the GATT characteristic inventory, revolution sequences, and delegates. Phase 3 added crank `start()` / `stop()`. Phase 4 serves wheel configurations and Set Cumulative Value. Phase 5 serves multiple sensor locations. Phase 6 adds Bluetooth loss recovery, the 30-second procedure timeout, and the one-live-server rule.

Characteristic order when present: CSC Measurement (`0x2A5B`), CSC Feature (`0x2A5C`), Sensor Location (`0x2A5D`), SC Control Point (`0x2A55`).

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

`SensorLocationKind` cases (GATT assigned numbers 0...16): `other`, `topOfShoe`, `inShoe`, `hip`, `frontWheel`, `leftCrank`, `rightCrank`, `leftPedal`, `rightPedal`, `frontHub`, `rearDropout`, `chainstay`, `rearWheel`, `rearHub`, `chest`, `spider`, `chainRing`.

### Sample App

- iOS-only SwiftUI client sample (`SampleApp`).

### Server Sample App

- iOS-only SwiftUI server sample (`SampleServerApp`) that advertises CSCS using `CSCServer` and simulates wheel/crank measurements.

#### Scan Screen

- Single screen — all sensor interaction happens on the list; no separate sensor detail screen.
- List view of discovered sensors.
- Scan or stop button.
- Displays relevant information for each sensor based on sensor state.
    - Use the State Pattern to determine what to display for a given sensor based on its state.
    - Discovered state:
        - Sensor info
        - Connect button
    - Connected state:
        - Sensor info
        - Speed if supported
        - Cadence if supported
        - Fixed location label or multiple-location picker with update control
        - Disconnect button
- Client-managed wheel size: the sample app holds and configures wheel circumference for speed display.
