# BluetoothBikeSensorSwift

## Summary

BluetoothBikeSensorSwift is a Swift package that scans for, connects to, and reads Bluetooth CSCS sensors. The Swift package name remains `BluetoothBikeSensorSwift`. Library products are **`CSCClient`** and **`CSCServer`**. `CSCWire` is an internal target, not a product. It includes the library and an iOS-only SwiftUI sample app. It uses SOLID principles and any other best practices as appropriate.

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

- **`CSCServer` is a library product as of Phase 2.** Phase 1 added the target and the peripheral seam (`BluetoothPeripheral`, `CoreBluetoothPeripheral`, `FakeBluetoothPeripheral`) without a product. Phase 2 publishes the product and a builder-only `Server`: `build()` records feature bits, the GATT inventory, revolution sequences, and delegates. It does not advertise or serve reads and writes. `CSCClient` does not depend on `CSCServer`. Phase 3’s `Server` remains the only production constructor of `CoreBluetoothPeripheral`; that instance is not passed into `Scanner`.
- **`Server` is built then started.** There is no public initializer. `Server: Sendable`. The initializer is `internal`. Session state lives on an internal `ServerRuntime` actor and a per-cycle `ServerSession` actor.
- **`start()` returns once advertising has started.** `stop()` is idempotent and returns only after advertising stops, the CSC service is removed, and measurement notifications end. Cancelling the task awaiting `start()` throws `CancellationError` after rolling back partial startup. If `startAdvertising` finishes after shutdown has begun, `ServerSession` stops advertising before `start()` throws. Any failed `open` rolls the session back, including the inbound read, write, subscription, and ready loops.
- **Phase 3 `start()` scope.** Crank-only and crank-plus-static-location only. Wheel data, multiple locations, or a missing crank sequence throw `ServerError.unsupportedConfiguration` without touching the radio. That guard is interim until Phase 4–5.
- **Power wait has no timeout.** On iOS the manager state can stay `.unknown` for the Bluetooth permission prompt. `CoreBluetoothPeripheral` replays the manager's current state on the peripheral queue immediately after `bind`, so a `didUpdateState` callback that fires during `init` is not lost.
- **Read responses (fake central and dynamic paths).** Cached characteristics return an offset slice (`0x07` past the end). Measurement reads return `0x02`. Unknown characteristics return `0x0A`. Writes return `0x03`.
- **Crank notifications.** Samples with no measurement subscribers are dropped. `updateValue` retries the same payload after `subscriberUpdatesReady` when the queue is full. `ServerSession` subscribes to `subscriberUpdatesReady` before `add` and latches the ready signal; `stop()` resumes a crank loop parked on that latch. `UInt16` crank cumulative rollover is passed through unchanged. When the crank sequence ends, reads and advertising continue; only notifications stop.
- **Restart caveat.** `start()` after `stop()` is allowed. A single-pass `AsyncStream` source is finished once `stop()` cancels its iteration; use a multi-pass sequence or a new `Server` to publish again with the same stream.
- **Stored configuration.** `wheel: WheelConfiguration?` pairs the sequence with the set-cumulative delegate. `location: ServerLocationConfiguration` is `.none`, `.staticLocation`, or `.multiple`. Set Cumulative Value follows `wheel != nil`. Update Sensor Location and Request Supported Sensor Locations follow `.multiple`. Start Sensor Calibration is not stored.
- **Delegates and sequences are stored and not called.** `build()` copies multiple-location `supported` and `current` and does not iterate sequences.
- **`BluetoothPeripheral`** exposes Bluetooth state, add/remove GATT services, start/stop advertising, read requests, write transactions (one `respond` per batch), CCCD subscription changes, `respond` with a read payload, and notify `updateValue` plus `subscriberUpdatesReady` when the transmit queue has space.
- **Queue crossing** — `CoreBluetoothPeripheral` creates `CBPeripheralManager` on serial queue `com.bluetoothbikesensor.peripheral`. The delegate bridge enqueues `Task { await handle(event) }` and returns. All manager calls run in `queue.sync` without holding the bridge lock across the sync. `add` and `startAdvertising` continuations resume on the actor. Only one in-flight `add` and one in-flight `startAdvertising` are allowed. `deinit` clears the handler and fails leftover continuations with `peripheralInvalidated` without calling `queue.sync`.
- **Subscribe before `add` and `startAdvertising`** — inbound streams do not replay; use `currentState` for the latest Bluetooth state.
- **Characteristic values** — a non-nil `value` is legal only when properties are exactly read and permissions are exactly readable (CoreBluetooth cached read). Any other combination throws `cachedValueNotReadOnly`. Nil `value` is dynamic; reads arrive on `readRequests`. The fake does not answer from a cached value.
- **CCCD (`0x2902`)** — subscription enable/disable is `didSubscribeTo` / `didUnsubscribeFrom`, not `writeTransactions`.
- **Read/write responses** — read success carries the offset slice in `respond`; the adaptor assigns it to `CBATTRequest.value` without re-slicing. The success slice may be empty; only `nil` is `missingReadValue`. One `respond` per write transaction uses the first `CBATTRequest`. Error bytes pass through `CBATTError.Code(rawValue:)` so application codes `0x80` / `0x81` survive.
- **Notify backpressure** — when `updateValue` returns `false`, `ServerSession` waits on a latched ready signal from `subscriberUpdatesReady` (subscribed before `add`) and retries the same payload; `stop()` resumes any waiter on that latch.
- **Control point** — the Phase 2 builder includes SC Control Point (`0x2A55`) on every server that has wheel revolution data or multiple sensor locations, and omits it for crank-only and crank-plus-static location (CSCS 1.0 §3.4 / Table 3.3). Issue #12 stays the client rule: wheel or wheel-and-crank `connect()` still succeeds when the peer omitted the control point and the multiple-locations bit is clear.

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

#### CSC Server (Phase 2–3)

Phase 2 adds a type-state builder on `Server` that records CSCS feature bits, the GATT characteristic inventory, revolution sequences, and delegates. Phase 3 adds `start()` / `stop()` for crank-only and crank-plus-static-location configurations.

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
