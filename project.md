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

- **`CSCServer` is a library product as of Phase 2.** Phase 1 added the target and the peripheral seam (`BluetoothPeripheral`, `CoreBluetoothPeripheral`, `FakeBluetoothPeripheral`) without a product. Phase 2 publishes the product and a builder-only `Server`: `build()` records feature bits, the GATT inventory, revolution sequences, and delegates. It does not advertise or serve reads and writes. `CSCClient` does not depend on `CSCServer`. Phase 3’s `Server` remains the only production constructor of `CoreBluetoothPeripheral`; that instance is not passed into `Scanner`.
- **`Server` is built then started.** There is no public initializer. `Server: Sendable`. The initializer is `internal`. Session state lives on an internal `ServerRuntime` actor and a per-cycle `ServerSession` actor.
- **`start()` returns once advertising has started.** `stop()` is idempotent and returns only after advertising stops, the CSC service is removed, and measurement notifications end. Cancelling the task awaiting `start()` throws `CancellationError` after rolling back partial startup. If `startAdvertising` finishes after shutdown has begun, `ServerSession` stops advertising before `start()` throws. Any failed `open` rolls the session back, including the inbound event loop.
- **Phase 4–5 `start()` scope.** Crank-only, crank-plus-static, wheel, wheel-plus-static, wheel-plus-crank, wheel-plus-crank-plus-static, and all three `.multiple` shapes. A missing crank sequence is valid when wheel data is present.
- **Power wait has no timeout (startup only).** On iOS the manager state can stay `.unknown` for the Bluetooth permission prompt. `CoreBluetoothPeripheral` replays the manager's current state on the peripheral queue immediately after `bind`, so a `didUpdateState` callback that fires during `init` is not lost. `ServerSession` records `powerLossCount` right after the wait; if the count changed by the time `startAdvertising` succeeds, startup rolls back and throws `.notPoweredOn`, even if power came back in between.
- **Read responses (fake central and dynamic paths).** Cached characteristics return an offset slice (`0x07` past the end). Multiple-location `0x2A5D` reads the served byte from runtime storage: offset `0` returns that byte, offset `1` returns success with empty `Data`, offset past the end returns `0x07`. Measurement reads return `0x02`. Unknown characteristics return `0x0A`. Writes that are not one control-point write on a service that contains `0x2A55` return `0x03`. A service with no `0x2A55` returns `0x03` for every write, including a write that names `0x2A55`. A non-zero offset on a present control point returns `0x07`. An empty control-point value, or a value for which `decode` returns `nil`, returns `0x0D`. A short `0x01` is `.invalidParameter`, not `nil`.
- **Measurement notifications.** Samples with no measurement subscribers are dropped and are not cached. One outbound pump is the only `updateValue` caller. It retries the same measurement payload, and the same control-point indication, after `.readyToUpdateSubscribers` when that call returns `false` and the session is still open. The inbound event loop signals the ready latch: it sets the bit when the pump is not parked, and resumes the pump when it is parked on the latch. The pump clears the bit immediately before every `updateValue`, so an idle ready signal cannot skip the next park. `stop()` resumes the pump if it is already parked and does not set the latch bit. The empty-queue park checks `closed` before waiting and again inside the continuation. `UInt16` crank cumulative rollover is passed through unchanged. When a revolution sequence ends, reads and advertising continue; only that source's notifications stop.
- **Restart caveat.** `start()` after `stop()` is allowed. A single-pass `AsyncStream` source is terminated once `stop()` cancels its iteration; use a multi-pass sequence or a new `Server` to publish again with the same stream. On multiple-location servers, the byte served on `0x2A5D` after restart is the last location `update` returned successfully, not the build-time `configuration.current` and not `delegate.current`. `Server.location` remains the build snapshot.
- **Stored configuration.** `wheel: WheelConfiguration?` pairs the sequence with the set-cumulative delegate. `location: SensorLocationConfiguration` is `.none`, `.staticLocation`, or `.multiple`. Set Cumulative Value follows `wheel != nil`. That sentence is builder storage. The write classifier keys off `0x2A55` being present in `service.characteristics`, not off `wheel != nil`. Update Sensor Location and Request Supported Sensor Locations follow `.multiple`. Start Sensor Calibration is not stored.
- **Delegates and sequences are stored until start().** `build()` stores sequences and delegates and does not iterate them. After `start()`, the session pulls crank and wheel sequences and calls `CumulativeWheelRevolutionsDelegate` for Set Cumulative Value. Multiple-location `supported` and `current` are snapshotted at `build()`. The served byte on `0x2A5D` lives on `ServerRuntime` for the life of the `Server`; do not read `Server.location` to learn it after Update. Request Supported Sensor Locations returns snapshot bytes in builder order (`10 04 01` plus raw assigned numbers, no length prefix). Update Sensor Location: `update(_:)` throw does not store the served byte; on success the argument is stored before the `closed` check and before enqueueing `10 03 01`, and the new byte is readable immediately even if the indication is backpressured or dropped; delegate throw or cancellation indicates `10 03 04` only when `!closed`, and `closed` suppresses the indication without skipping a successful store. Crank-only multiple servers indicate `10 01 02` for Set Cumulative Value. Location indications use the Phase 4 outbound pump.
- **`BluetoothPeripheral`** exposes Bluetooth state, add/remove GATT services, start/stop advertising, `respond` (one per write transaction, with a read payload for reads), and notify `updateValue`. Inbound traffic arrives on one ordered `events` stream: state updates, read requests, write transactions, CCCD subscription changes, and ready-to-update signals, in callback order. `stateUpdates` is used only by the startup power wait. `powerLossCount` counts transitions out of `.poweredOn`.
- **Queue crossing** — `CoreBluetoothPeripheral` creates `CBPeripheralManager` on serial queue `com.bluetoothbikesensor.peripheral`. The delegate bridge yields each callback into a FIFO channel that one task drains in order. All manager calls run in `queue.sync` without holding the bridge lock across the sync. `add` and `startAdvertising` continuations resume on the actor. Only one in-flight `add` and one in-flight `startAdvertising` are allowed. On leaving `.poweredOn`, the peripheral fails in-flight continuations with `.notPoweredOn`, prunes subscribed centrals and stored requests, and increments `powerLossCount`. While not powered on, `add`, `startAdvertising`, `updateValue`, and `respond` throw `.notPoweredOn`, `stopAdvertising` makes no manager call, and `removeService` / `removeAllServices` drop only bookkeeping. Only `close()` or `rollbackStartup()` removes a service while not powered on, and that peripheral is then discarded; recovery never depends on bookkeeping a rollback dropped. `deinit` clears the handler and fails leftover continuations with `peripheralInvalidated` without calling `queue.sync`.
- **Subscribe before `add` and `startAdvertising`** — `events` does not replay, so the session subscribes before `add`. Events that arrive during startup are buffered and drained in order before the startup gate opens and before the revolution loops start; the gate flips synchronously after the drain returns. Use `currentState` for the latest Bluetooth state.
- **Characteristic values** — a non-nil `value` is legal only when properties are exactly read and permissions are exactly readable (CoreBluetooth cached read). Any other combination throws `cachedValueNotReadOnly`. Nil `value` is dynamic; reads arrive on `events`. The fake does not answer from a cached value.
- **CCCD (`0x2902`)** — subscription enable/disable is `didSubscribeTo` / `didUnsubscribeFrom` (`.subscription` events), not `.writeTransaction` events.
- **Read/write responses** — read success carries the offset slice in `respond`; the adaptor assigns it to `CBATTRequest.value` without re-slicing. The success slice may be empty; only `nil` is `missingReadValue`. One `respond` per write transaction uses the first `CBATTRequest`. Error bytes pass through `CBATTError.Code(rawValue:)` so application codes `0x80` / `0x81` survive.
- **Notify backpressure** — when `updateValue` returns `false` and the session is still open, the outbound pump waits on the ready latch and retries the same payload, whether that payload is a measurement or a control-point indication. `events` is subscribed before `add`. The inbound event loop sets the latch bit when the pump is not parked on it; the pump clears the bit before every `updateValue`. `stop()` resumes a pump already parked on that latch and does not set the bit. A successful Set Cumulative wakes a parked ready waiter the same way, without setting the bit. An empty measurement subscriber set drops a measurement. Control-point unsubscribe removes every queued indication for that central, at any position in the queue, and ends the procedure that owned one; if the removed item was at the head, it also wakes a parked ready waiter without setting the latch bit.
- **Control point** — the Phase 2 builder includes SC Control Point (`0x2A55`) on every server that has wheel revolution data or multiple sensor locations, and omits it for crank-only and crank-plus-static location (CSCS 1.0 §3.4 / Table 3.3). Issue #12 stays the client rule: wheel or wheel-and-crank `connect()` still succeeds when the peer omitted the control point and the multiple-locations bit is clear.
- **Pass-through cumulative.** Notify the sequence `UInt32` as-is, including `0`, `UInt32.max`, and decreases. No server clamp and no rollover arithmetic.
- **Set Cumulative Value does not synthesize a measurement.** It calls the delegate. Success indicates `10 01 01` only when the session is still open.
- **Delegate throw indicates Operation Failed** (`10 01 04`) when `!closed`. The write response has already succeeded. A `false` indication return retries the same bytes and does not call `endProcedure()`.
- **Companion caches are per producing source.** Write `wheelCache` only when `updateValue` returns `true` and the item is current (the discard predicate is false, including a nil `encodedWheelGeneration`). Write `crankCache` in that same current case and also when a stale crank-produced payload returns `true`. Do not write `wheelCache` on that stale `true`. On measurement `true` and indication `true`, remove the head. Successful Set Cumulative increments `wheelGeneration` and nils `wheelCache` before the success indication is queued.
- **`wheelGeneration` discard.** The pump drops every stale wheel-bearing payload, including combined, before send and after every measurement return. A stale wheel-source head is removed and its emit waiter is completed once.
- **Crank-half replacement.** An unsent crank-produced combined item is replaced in place and that crank-only `Data` is sent in the same pump turn with no ready wait before that send.
- **Procedure idle until indication accept.** `procedureInProgress` stays set until the indication `updateValue` returns `true`, the indication central unsubscribes, the 30-second timeout ends it, or shutdown or a throw discards it. A `false` return retries instead of ending the procedure. A send already inside `updateValue` cannot be recalled; if something else ended the procedure meanwhile, the pump's head re-check makes that return a no-op.
- **Characteristic-absent write gate.** A service that lacks `0x2A55` returns `0x03` for every write, including a write that names `0x2A55`. That gate runs before offset, length, CCCD, and `0x80`.
- **`emit` after `closed` does not park.** The pump is the only `completeEmit` resumer. `beginShutdown` does not resume emit waiters.
- **No spawn or enqueue once `closed`.** The classified `respond` still happens once on a write after shutdown begins. A success `respond` on that path has no indication; `endProcedure()` if the flag was set.
- **Empty-queue double-check.** The empty-queue park checks `closed` before waiting and again inside the continuation, the same way `waitForNotifyReady` does.
- **The inbound event loop sets the ready latch; the pump clears it before each send.** The loop is the only resumer that sets the bit, and only when the pump is not parked. The pump sets `notifyReady = false` immediately before every `updateValue`; CoreBluetooth calls `peripheralManagerIsReady` after every `false` return, so no wakeup is lost. `beginShutdown` and a successful Set Cumulative wake a parked ready waiter without setting the bit.
- **One outbound pump.** It is the only `updateValue` caller and the only emit resumer. It owns the ready latch, the queue latch, and emit completion.
- **30-second procedure timeout (CSCS §3.4.4).** CoreBluetooth never reports the ATT confirmation, so the server bounds what it controls: one 30 s budget per procedure, starting after the success response to the write and ending when the procedure's indication `updateValue` returns `true` or the procedure ends another way. Writes answered with an ATT error never arm it. On expiry the indication is never passed to `updateValue` again: a queued indication is removed wherever it sits and the procedure ends; a running delegate call is cancelled and the procedure ends when it returns, so delegate calls never overlap. A delegate success after the deadline keeps its side effect (stored location, `wheelGeneration` bump) and is not indicated. The clock is an injected `package` `ServerClock`.
- **Sticky sample gate.** `wheelSequenceEndStopsNotificationsOnly` awaits `start()` before the subscriber wait and does not hold advertise.
- **`waitUntilNextEntered` fast path.** Returns immediately when the entry count is already ≥ target, rechecks inside the continuation, and on increment resumes only waiters whose target is ≤ N.
- **Bluetooth leaves `.poweredOn` (D1).** Startup contract: `start()` returns only after `add` and `startAdvertising` succeed and `powerLossCount` is unchanged since the power wait; otherwise it rolls back and throws `.notPoweredOn`. Startup still fails fast for `.poweredOff`, `.unauthorized`, and `.unsupported`, and waits through `.unknown` and `.resetting`. Running contract: any state other than `.poweredOn` suspends the session. Suspend clears both subscriber sets, lets the pump discard queued items, keeps iterating the sequences (samples drop for lack of subscribers), keeps `wheelCache` / `crankCache` and the served location, bumps a loss epoch so an in-flight measurement is not cached, and leaves `publishStage` unchanged. The next transition into `.poweredOn` runs recovery: `stopAdvertising`, remove the service if published, `add` the build-time service, `startAdvertising`, checking `closed` after every await. A failed recovery leaves the server running and suspended with no throw and no status; it retries only after Bluetooth leaves `.poweredOn` and returns. A duplicate `.poweredOn` or a second loss does nothing.

  | Event | `publishStage` after |
  |---|---|
  | Startup `add` succeeds | `.serviceAdded` |
  | Startup `startAdvertising` succeeds | `.advertising` |
  | Suspend | unchanged |
  | Recovery removes the old service | `.none` |
  | Recovery `add` succeeds | `.serviceAdded` |
  | Recovery `add` fails | `.none` |
  | Recovery `startAdvertising` succeeds | `.advertising` |
  | Recovery `startAdvertising` fails, or recovery sees `closed` after `add` | `.none`, after its `removeService` |
  | `close()` / `rollbackStartup()` | `.none`, after their `removeService` if the stage was not `.none` |

- **Public status is subscriber count only; unauthorized is `.notPoweredOn` (D2 / D3).** ``Server/measurementSubscriberCount`` is an `AsyncStream<Int>` of centrals subscribed to CSC Measurement notifications (0 while stopped, starting, or when Bluetooth loss suspends the server). There is no public advertising or Bluetooth power API. Tests observe radio suspension through the `package` hook `isRadioSuspended`. A distinct unauthorized error would break exhaustive switches over the public non-frozen `ServerError`, so apps check `CBManager.authorization` instead.
- **One live server per process (D5).** `LiveServerRegistry.shared` holds a single slot. `start()` claims it on entry, before resolving the peripheral and before the power wait; another `Server`'s `start()` throws `.alreadyStarted` and touches no peripheral. The slot is released only after `stop()` teardown, or after a failed or cancelled startup has rolled back. `ServerRuntime` phases are `idle`, `starting`, `running`, and `stopping`; `stopping` holds the teardown task so a second `stop()` waits on the same teardown. The package `start(peripheral:clock:liveServers:)` overload defaults to a fresh registry so tests stay isolated.

  | Event | `phase` | `lease` |
  |---|---|---|
  | `start()` entered, claim succeeds | `.starting` | held |
  | `start()` entered, claim fails | unchanged | unchanged; throws `.alreadyStarted`; no peripheral |
  | `start()` while `.stopping` | unchanged | unchanged; throws `.alreadyStarted` |
  | Startup succeeds | `.running` | held |
  | Startup fails or is cancelled, this runtime still owns it | `.stopping`, then `.idle` after rollback or `close` | released after that |
  | `stop()` from `.running` | `.stopping` until `close` returns, then `.idle` | released after `close` |
  | `stop()` from `.starting` | `.stopping`, then `.idle` | released on every exit |
  | `stop()` when already `.idle` with no lease | `.idle` | no release |
  | A second `stop()` or a `deinit` task overlapping a `stop()` | waits on the same `.stopping` task | one release |

- **Releasing a started `Server` stops it (D6).** `Server.deinit` schedules `stop()` in a task. The slot is released after that background teardown, so another `Server`'s `start()` can still throw `.alreadyStarted` until then; apps that need to start another server immediately `await stop()` first.
- **Feature bits fixed after `build()`.** CSC Feature and the characteristic inventory are fixed at `build()` for the life of the `Server`, including across `stop()`/`start()` and Bluetooth recovery. To change features, stop and build a new `Server`. A new `Server` publishes a new GATT database; centrals may need to reconnect and rediscover. This library does not implement Service Changed.
- **Outbound queue invariants.** The pump is the only `updateValue` caller. Only the pump removes a measurement at the head of the queue; removals from outside the pump (unsubscribe, timeout, radio loss) remove indications by id only. There is no second pump. A send already inside `updateValue` cannot be recalled; after every await the pump re-checks that its indication is still the head before ending the procedure.
- **`AsyncStream` sources (D8).** The builder accepts any `AsyncSequence & Sendable` source, including sequences whose iterator is not `Sendable`. `AnyAsyncSequence` boxes each iterator, and `ServerSession` iterates each box from exactly one task.

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
