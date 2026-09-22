# BluetoothBikeSensorSwift

## Summary

BluetoothBikeSensorSwift is a Swift package that scans for, connects to, and reads Bluetooth CSCS sensors. It includes the library and an iOS-only SwiftUI sample app. It uses SOLID principles and any other best practices as appropriate.

## Decisions

- **`Scanner` is instantiable** with dependencies passed through its initializer (not a singleton).
- **`DiscoveredSensor` and `ConnectedSensor` have internal initializers only** — no public `CBPeripheral` initializers.
- **Wheel size is client-managed** — the client supplies wheel circumference (or equivalent) for speed calculation; the library does not read, write, or persist wheel size.
- **Sample app is iOS-only**, built with SwiftUI.
- **Sample app uses a single Scan list screen** — no separate sensor detail screen; row content is driven by a State Pattern for discovered vs connected states.
- **`Speed` and `Cadence` are Foundation `Measurement` typealiases** — `Speed` is `Measurement<UnitSpeed>`; `Cadence` is `Measurement<UnitFrequency>`. The library provides `UnitFrequency.revolutionsPerMinute` (`"rpm"`) for cadence values.
- **Wheel data requires SC Control Point at connect** — per CSCS, Set Cumulative Value is mandatory when wheel data is supported; non-compliant peripherals fail `connect()`.
- **`SensorLocation` is not publicly constructible** — clients obtain tokens from the peripheral and compare via `SensorLocation.Kind`; future `CSCServer` builder will accept `Kind` values.
- **Start Sensor Calibration (`0x02`) is not supported** — the client does not expose this control-point procedure.

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
- Wheel or wheel-and-crank connect fails when SC Control Point (`0x2A55`) is missing.
- Has a single function `disconnect()` returning `async` `DiscoveredSensor`, throwing `DisconnectError`.

#### WheelRevolutions

- Client-managed `wheelCircumference` (default 2.105 m); used for speed and wheel delta distance.
- `speed: AsyncStream<Speed>` and `wheelSamples: AsyncStream<WheelSample>`.
- `setCumulativeRevolutions(_:)` writes Set Cumulative Value (`0x01`) via SC Control Point.

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

### Sample App

- iOS-only SwiftUI app.

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
