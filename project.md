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
- **Phase 4–5 `start()` scope.** Crank-only, crank-plus-static, wheel, wheel-plus-static, wheel-plus-crank, wheel-plus-crank-plus-static, and all three `.multiple` shapes. A missing crank sequence is valid when wheel data is present.
- **Power wait has no timeout.** On iOS the manager state can stay `.unknown` for the Bluetooth permission prompt. `CoreBluetoothPeripheral` replays the manager's current state on the peripheral queue immediately after `bind`, so a `didUpdateState` callback that fires during `init` is not lost.
- **Read responses (fake central and dynamic paths).** Cached characteristics return an offset slice (`0x07` past the end). Multiple-location `0x2A5D` reads the served byte from runtime storage: offset `0` returns that byte, offset `1` returns success with empty `Data`, offset past the end returns `0x07`. Measurement reads return `0x02`. Unknown characteristics return `0x0A`. Writes that are not one control-point write on a service that contains `0x2A55` return `0x03`. A service with no `0x2A55` returns `0x03` for every write, including a write that names `0x2A55`. A non-zero offset on a present control point returns `0x07`. An empty control-point value, or a value for which `decode` returns `nil`, returns `0x0D`. A short `0x01` is `.invalidParameter`, not `nil`.
- **Measurement notifications.** Samples with no measurement subscribers are dropped and are not cached. One outbound pump is the only `updateValue` caller. It retries the same measurement payload, and the same control-point indication, after `subscriberUpdatesReady` when that call returns `false` and the session is still open. `ServerSession` still subscribes to `subscriberUpdatesReady` before `add`. `spawnReadyLoop` latches that signal when the pump is inside `updateValue`, and resumes the pump when it is parked on the ready latch. `stop()` resumes the pump if it is already parked and does not set the latch bit. The empty-queue park checks `closed` before waiting and again inside the continuation. `UInt16` crank cumulative rollover is passed through unchanged. When a revolution sequence ends, reads and advertising continue; only that source's notifications stop.
- **Restart caveat.** `start()` after `stop()` is allowed. A single-pass `AsyncStream` source is finished once `stop()` cancels its iteration; use a multi-pass sequence or a new `Server` to publish again with the same stream. On multiple-location servers, the byte served on `0x2A5D` after restart is the last location `update` returned successfully, not the build-time `configuration.current` and not `delegate.current`. `Server.location` remains the build snapshot.
- **Stored configuration.** `wheel: WheelConfiguration?` pairs the sequence with the set-cumulative delegate. `location: ServerLocationConfiguration` is `.none`, `.staticLocation`, or `.multiple`. Set Cumulative Value follows `wheel != nil`. That sentence is builder storage. The write classifier keys off `0x2A55` being present in `service.characteristics`, not off `wheel != nil`. Update Sensor Location and Request Supported Sensor Locations follow `.multiple`. Start Sensor Calibration is not stored.
- **Delegates and sequences are stored until start().** `build()` stores sequences and delegates and does not iterate them. After `start()`, the session pulls crank and wheel sequences and calls `SetCumulativeWheelRevolutions` for Set Cumulative Value. Multiple-location `supported` and `current` are snapshotted at `build()`. The served byte on `0x2A5D` lives on `ServerRuntime` for the life of the `Server`; do not read `Server.location` to learn it after Update. Request Supported Sensor Locations returns snapshot bytes in builder order. Update Sensor Location calls `update(_:)`; on success the argument is stored before enqueueing `10 03 01`, and the new byte is readable immediately even if the indication is backpressured or dropped. Crank-only multiple servers indicate `10 01 02` for Set Cumulative Value. Location indications use the Phase 4 outbound pump.
- **`BluetoothPeripheral`** exposes Bluetooth state, add/remove GATT services, start/stop advertising, read requests, write transactions (one `respond` per batch), CCCD subscription changes, `respond` with a read payload, and notify `updateValue` plus `subscriberUpdatesReady` when the transmit queue has space.
- **Queue crossing** — `CoreBluetoothPeripheral` creates `CBPeripheralManager` on serial queue `com.bluetoothbikesensor.peripheral`. The delegate bridge enqueues `Task { await handle(event) }` and returns. All manager calls run in `queue.sync` without holding the bridge lock across the sync. `add` and `startAdvertising` continuations resume on the actor. Only one in-flight `add` and one in-flight `startAdvertising` are allowed. `deinit` clears the handler and fails leftover continuations with `peripheralInvalidated` without calling `queue.sync`.
- **Subscribe before `add` and `startAdvertising`** — inbound streams do not replay; use `currentState` for the latest Bluetooth state.
- **Characteristic values** — a non-nil `value` is legal only when properties are exactly read and permissions are exactly readable (CoreBluetooth cached read). Any other combination throws `cachedValueNotReadOnly`. Nil `value` is dynamic; reads arrive on `readRequests`. The fake does not answer from a cached value.
- **CCCD (`0x2902`)** — subscription enable/disable is `didSubscribeTo` / `didUnsubscribeFrom`, not `writeTransactions`.
- **Read/write responses** — read success carries the offset slice in `respond`; the adaptor assigns it to `CBATTRequest.value` without re-slicing. The success slice may be empty; only `nil` is `missingReadValue`. One `respond` per write transaction uses the first `CBATTRequest`. Error bytes pass through `CBATTError.Code(rawValue:)` so application codes `0x80` / `0x81` survive.
- **Notify backpressure** — when `updateValue` returns `false` and the session is still open, the outbound pump waits on the ready latch and retries the same payload, whether that payload is a measurement or a control-point indication. `subscriberUpdatesReady` is subscribed before `add`. `spawnReadyLoop` sets the latch bit when the pump is inside `updateValue`. `stop()` resumes a pump already parked on that latch and does not set the bit. A successful Set Cumulative wakes a parked ready waiter the same way, without setting the bit. An empty measurement subscriber set drops a measurement. A control-point indication whose central has unsubscribed is dropped and the procedure ends; control-point unsubscribe wakes a parked ready waiter without setting the latch bit.
- **Control point** — the Phase 2 builder includes SC Control Point (`0x2A55`) on every server that has wheel revolution data or multiple sensor locations, and omits it for crank-only and crank-plus-static location (CSCS 1.0 §3.4 / Table 3.3). Issue #12 stays the client rule: wheel or wheel-and-crank `connect()` still succeeds when the peer omitted the control point and the multiple-locations bit is clear.
- **Pass-through cumulative.** Notify the sequence `UInt32` as-is, including `0`, `UInt32.max`, and decreases. No server clamp and no rollover arithmetic.
- **Set Cumulative Value does not synthesize a measurement.** It calls the delegate. Success indicates `10 01 01` only when the session is still open.
- **Delegate throw indicates Operation Failed** (`10 01 04`) when `!closed`. The write response has already succeeded. A `false` indication return retries the same bytes and does not call `endProcedure()`.
- **Companion caches are per producing source.** Write `wheelCache` only when `updateValue` returns `true` and the item is current (the discard predicate is false, including a nil `encodedWheelGeneration`). Write `crankCache` in that same current case and also when a stale crank-produced payload returns `true`. Do not write `wheelCache` on that stale `true`. On measurement `true` and indication `true`, remove the head. Successful Set Cumulative increments `wheelGeneration` and nils `wheelCache` before the success indication is queued.
- **`wheelGeneration` discard.** The pump drops every stale wheel-bearing payload, including combined, before send and after every measurement return. A stale wheel-source head is removed and its emit waiter is completed once.
- **Crank-half replacement.** An unsent crank-produced combined item is replaced in place and that crank-only `Data` is sent in the same pump turn with no ready wait before that send.
- **Procedure idle until indication accept.** `procedureInProgress` stays set until the indication `updateValue` returns `true`, the indication central unsubscribes, or shutdown or a throw discards it. A `false` return retries instead of ending the procedure.
- **Characteristic-absent write gate.** A service that lacks `0x2A55` returns `0x03` for every write, including a write that names `0x2A55`. That gate runs before offset, length, CCCD, and `0x80`.
- **`emit` after `closed` does not park.** The pump is the only `completeEmit` resumer. `beginShutdown` does not resume emit waiters.
- **No spawn or enqueue once `closed`.** The classified `respond` still happens once on a write after shutdown begins. A success `respond` on that path has no indication; `endProcedure()` if the flag was set.
- **Empty-queue double-check.** The empty-queue park checks `closed` before waiting and again inside the continuation, the same way `waitForNotifyReady` does.
- **`spawnReadyLoop` sets the ready latch.** It is the resumer that sets the bit when the pump is inside `updateValue`. `beginShutdown` and a successful Set Cumulative wake a parked ready waiter without setting the bit.
- **One outbound pump.** It is the only `updateValue` caller and the only emit resumer. It owns the ready latch, the queue latch, and emit completion.
- **No ATT confirmation timeout.** Procedure completion is `updateValue == true` for an indication, or a `closed` / throw discard.
- **Sticky sample gate.** `wheelSequenceEndStopsNotificationsOnly` awaits `start()` before the subscriber wait and does not hold advertise.
- **`waitUntilNextEntered` fast path.** Returns immediately when the entry count is already ≥ target, rechecks inside the continuation, and on increment resumes only waiters whose target is ≤ N.

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

#### CSC Server (Phase 2–5)

Phase 2 adds a type-state builder on `Server` that records CSCS feature bits, the GATT characteristic inventory, revolution sequences, and delegates. Phase 3 added crank `start()` / `stop()`. Phase 4 serves wheel configurations and Set Cumulative Value. Phase 5 serves multiple sensor locations.

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
