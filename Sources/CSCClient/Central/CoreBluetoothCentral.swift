#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// Production ``BluetoothCentral`` backed by `CBCentralManager`.
///
/// Delegate callbacks arrive on `queue` (`com.bluetoothbikesensor.central`), not on this actor.
/// ``CentralDelegateBridge`` turns each callback into a ``CentralDelegateEvent`` and yields it
/// on one FIFO stream. A single task drains that stream into ``handle(_:)``, which is what keeps
/// callback order. Direct `CBCentralManager` and `CBPeripheral` calls run inside `queue.sync`
/// from actor methods. The actor is blocked for the duration of `sync`, and the serial queue
/// cannot deliver another callback until `sync` returns, so commands and callbacks do not
/// interleave.
///
/// In-flight GATT and connection calls each hold one continuation in `pending`, keyed by
/// ``Request``. A second call with the same key fails immediately instead of queueing.
/// Connect cancellation is separate from that map: the waiter is failed as soon as the task
/// is cancelled, and ``ConnectCancelCoordinator`` remembers that the radio may still be
/// tearing the link down.
actor CoreBluetoothCentral: BluetoothCentral {
    private let queue = DispatchQueue(label: "com.bluetoothbikesensor.central")
    private let centralManager: CBCentralManager
    private let delegateBridge: CentralDelegateBridge
    private let delegateEvents: AsyncStream<CentralDelegateEvent>.Continuation

    private var state: BluetoothState = .unknown

    /// Continuations for calls that have not yet seen their callback. Connect, disconnect, and
    /// the two discovery calls are keyed by peripheral only. Read, write, and set-notify also
    /// include the service and characteristic.
    private var pending: [Request: CheckedContinuation<Data, Error>] = [:]

    /// Peripherals for which `CBCentralManager.connect` has been issued and has not yet
    /// completed, failed, or been cancelled. A `didConnect` whose id is absent here is ignored,
    /// so a late callback cannot complete a connect that already returned or was cancelled.
    private var pendingConnect: Set<UUID> = []

    private var connectCancel = ConnectCancelCoordinator()

    /// Session id passed to the `startScanning` that last turned the radio on. `0` means this
    /// central is not scanning. A `stopScanning` whose session does not match leaves the radio
    /// alone.
    private var activeScanSession: UInt64 = 0

    /// Highest session id for which `stopScanning` has been asked. `startScanning` ignores a
    /// session at or below this, which is how a stop that wins the race with its own start
    /// never turns the radio on, and how a stale start cannot restart a scan that already stopped.
    private var highestStoppedScanSession: UInt64 = 0

    private let stateBroadcaster = StreamBroadcaster<BluetoothState>()
    private let discoveryBroadcaster = StreamBroadcaster<DiscoveredPeripheral>()
    private let eventsBroadcaster = StreamBroadcaster<CentralEvent>()

    /// Wires the delegate bridge to a FIFO stream drained by one actor-isolated task, so
    /// callbacks that fire on `queue` are serialized onto the actor in arrival order before
    /// ``handle(_:)`` touches any state.
    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CentralDelegateEvent.self)
        let bridge = CentralDelegateBridge(events: continuation)
        delegateBridge = bridge
        delegateEvents = continuation
        centralManager = CBCentralManager(delegate: bridge, queue: queue)
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    /// Finishes the delegate stream so the drain task ends. Does not call `queue.sync`, which
    /// could block teardown on the manager queue, and does not resume `pending` continuations.
    /// Callers hold this actor for the lifetime of an in-flight connect or GATT call (a
    /// discovered or connected sensor retains the central).
    deinit {
        delegateEvents.finish()
    }

    package var stateUpdates: AsyncStream<BluetoothState> {
        get async { await stateBroadcaster.makeStream() }
    }

    package var currentState: BluetoothState {
        get async { state }
    }

    /// Subscribes, then reads `state`, with no further await between the two. A transition
    /// handled while `makeStream` was suspending is already in `state` or still queued behind
    /// this method, and the new subscriber is registered before that queued handling runs.
    package func stateSubscriptionSnapshot() async -> (AsyncStream<BluetoothState>, BluetoothState) {
        (await stateBroadcaster.makeStream(), state)
    }

    /// Starts a scan only when `session` is newer than every session already stopped and the
    /// radio is `.poweredOn`. `AllowDuplicates` is false; iOS also coalesces background
    /// discoveries on its own. Replacing `activeScanSession` does not stop the previous
    /// session's radio scan — `scanForPeripherals` replaces it — so the older session's later
    /// `stopScanning` no longer matches and will not turn the radio off.
    package func startScanning(serviceUUIDs: [UUID]?, session: UInt64) async {
        guard session > highestStoppedScanSession else { return }
        guard state == .poweredOn else { return }
        activeScanSession = session
        queue.sync {
            centralManager.scanForPeripherals(
                withServices: serviceUUIDs?.map(\.cbUUID),
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false],
            )
        }
    }

    /// Records `session` as stopped even when it is not the active scan, so a start that has
    /// not run yet still sees ``highestStoppedScanSession`` and stays off. The radio is stopped
    /// only when `session` is ``activeScanSession``.
    package func stopScanning(session: UInt64) async {
        if session > highestStoppedScanSession {
            highestStoppedScanSession = session
        }
        guard activeScanSession == session else { return }
        activeScanSession = 0
        queue.sync { centralManager.stopScan() }
    }

    package var discoveries: AsyncStream<DiscoveredPeripheral> {
        get async { await discoveryBroadcaster.makeStream() }
    }

    /// Connects, or returns immediately when the peripheral is already `.connected` and no
    /// cancel is pending.
    ///
    /// Peripheral state and the cancel-pending flag are read together on `queue`. If a cancel
    /// is still tearing the link down, this does not treat `.connected` as success: the request
    /// stays in `pending` until ``ConnectCancelCoordinator`` reports the link is down, and
    /// ``issueConnectIfPending(id:)`` starts it then.
    ///
    /// Cancelling the caller runs ``cancelConnect(id:)`` on this actor. The cancellation
    /// handler cannot hop here itself, so it schedules a task. The waiter is resumed with
    /// `CancellationError` from that method, not from this one.
    package func connect(id: UUID) async throws {
        guard state == .poweredOn else { throw BluetoothCentralError.notPoweredOn }
        let connectionState = queue.sync { () -> (found: Bool, connected: Bool, cancelPending: Bool) in
            guard let peripheral = delegateBridge.peripheral(for: id) else {
                return (false, false, false)
            }
            let cancelPending = connectCancel.isCancelPending(id)
            return (true, peripheral.state == .connected, cancelPending)
        }
        guard connectionState.found else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        if connectionState.connected, !connectionState.cancelPending {
            return
        }
        try await withTaskCancellationHandler {
            _ = try await enqueue(.connect(id)) {
                queue.sync { connectPeripheral(id: id, request: .connect(id)) }
            }
        } onCancel: {
            Task { await self.cancelConnect(id: id) }
        }
    }

    /// Disconnects. A peripheral that is already `.disconnected` returns without a callback and
    /// without yielding ``CentralEvent/disconnected``. A missing peripheral is
    /// ``BluetoothCentralError/peripheralNotFound``, which ``ConnectedSensor/disconnect()`` maps
    /// to ``DisconnectError/alreadyDisconnected``.
    package func disconnect(id: UUID) async throws {
        let peripheralState = queue.sync { () -> CBPeripheralState? in
            delegateBridge.peripheral(for: id)?.state
        }
        guard let peripheralState else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        if peripheralState == .disconnected { return }

        _ = try await enqueue(.disconnect(id)) {
            queue.sync { disconnectPeripheral(id: id, request: .disconnect(id)) }
        }
    }

    package var events: AsyncStream<CentralEvent> {
        get async { await eventsBroadcaster.makeStream() }
    }

    package func discoverServices(id: UUID, serviceUUIDs: [UUID]?) async throws {
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        let request = Request.discoverServices(id)
        _ = try await enqueue(request) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                peripheral.discoverServices(serviceUUIDs?.map(\.cbUUID))
            }
        }
    }

    /// Discovers characteristics, then returns the UUIDs present on `serviceUUID`.
    ///
    /// The returned list is read on `queue` after the callback. If the peripheral or service
    /// disappeared between the callback and that read, the list is empty and this does not
    /// throw; the discover request itself already completed. Callers treat a missing required
    /// characteristic as a later read or as an absent feature, not as a throw from here.
    package func discoverCharacteristics(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUIDs: [UUID]?,
    ) async throws -> [UUID] {
        guard delegateBridge.peripheral(for: id) != nil else {
            throw BluetoothCentralError.peripheralNotFound(id)
        }
        let request = Request.discoverCharacteristics(id)
        _ = try await enqueue(request) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                guard let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID }) else {
                    complete(
                        request,
                        throwing: BluetoothCentralError.serviceNotFound(id, serviceUUID: serviceUUID),
                    )
                    return
                }
                peripheral.discoverCharacteristics(characteristicUUIDs?.map(\.cbUUID), for: service)
            }
        }
        return queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id),
                  let service = peripheral.services?.first(where: { $0.uuid.foundationUUID == serviceUUID })
            else { return [] }
            return service.characteristics?.compactMap { $0.uuid.foundationUUID } ?? []
        }
    }

    package func setNotifyValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        enabled: Bool,
    ) async throws {
        _ = try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .setNotify($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    package func readValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) async throws -> Data {
        try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .read($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.readValue(for: characteristic)
        }
    }

    package func writeValue(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        value: Data,
    ) async throws {
        _ = try await performGATT(
            id: id,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            request: { .write($0, $1, $2) },
        ) { peripheral, characteristic in
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
        }
    }

    /// Parks one continuation per ``Request`` key, then runs `work` before this method suspends.
    /// `work` is expected to call `complete` now (the peripheral is already gone) or from a
    /// later ``handle(_:)``. A key that is already pending fails with
    /// ``BluetoothCentralError/connectionFailed`` reason `"Request already in progress"` and
    /// does not start a second operation.
    private func enqueue(_ request: Request, work: () -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            guard pending[request] == nil else {
                continuation.resume(throwing: request.duplicateInProgressError)
                return
            }
            pending[request] = continuation
            work()
        }
    }

    private func complete(_ request: Request, returning data: Data = Data()) {
        guard let continuation = pending.removeValue(forKey: request) else { return }
        continuation.resume(returning: data)
    }

    private func complete(_ request: Request, throwing error: Error) {
        guard let continuation = pending.removeValue(forKey: request) else { return }
        continuation.resume(throwing: error)
    }

    /// A nil `errorReason` completes the request successfully. A string fails it as
    /// ``BluetoothCentralError/connectionFailed``. Used for discovery and notify callbacks,
    /// whose CoreBluetooth errors arrive as text rather than an ATT code.
    private func complete(_ request: Request, id: UUID, errorReason: String?) {
        if let errorReason {
            complete(request, throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason))
        } else {
            complete(request)
        }
    }

    /// Looks the characteristic up on `queue` and issues the CoreBluetooth call there, or
    /// completes the request immediately when the peripheral is missing, not connected, or has
    /// no such characteristic. Failing a disconnected peripheral here is what keeps
    /// ``ConnectedSensor/disconnect()`` from waiting on a notify callback that will not arrive.
    private func performGATT(
        id: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        request: (UUID, UUID, UUID) -> Request,
        perform: (CBPeripheral, CBCharacteristic) -> Void,
    ) async throws -> Data {
        let gattRequest = request(id, serviceUUID, characteristicUUID)
        return try await enqueue(gattRequest) {
            queue.sync {
                guard let peripheral = delegateBridge.peripheral(for: id) else {
                    complete(gattRequest, throwing: BluetoothCentralError.peripheralNotFound(id))
                    return
                }
                guard peripheral.state == .connected else {
                    complete(
                        gattRequest,
                        throwing: BluetoothCentralError.disconnected(id, reason: nil),
                    )
                    return
                }
                guard let characteristic = Self.characteristic(
                    on: peripheral,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                ) else {
                    complete(
                        gattRequest,
                        throwing: BluetoothCentralError.characteristicNotFound(
                            id,
                            serviceUUID: serviceUUID,
                            characteristicUUID: characteristicUUID,
                        ),
                    )
                    return
                }
                perform(peripheral, characteristic)
            }
        }
    }

    /// Called on `queue` from ``connect(id:)``.
    ///
    /// If a cancel is still pending, returns without calling `connect` and without completing
    /// `request`. The continuation stays in `pending` until teardown retries it. If the
    /// peripheral is already connected, completes the request and does not add it to
    /// ``pendingConnect``. Otherwise records the id in ``pendingConnect`` before
    /// `CBCentralManager.connect`, so only a callback for that attempt can complete it.
    private func connectPeripheral(id: UUID, request: Request) {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
            return
        }
        if connectCancel.isCancelPending(id) {
            return
        }
        if peripheral.state == .connected {
            complete(request)
            return
        }
        pendingConnect.insert(id)
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnectPeripheral(id: UUID, request: Request) {
        guard let peripheral = delegateBridge.peripheral(for: id) else {
            complete(request, throwing: BluetoothCentralError.peripheralNotFound(id))
            return
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Fails the in-flight connect waiter, if one is still pending, and asks the radio to drop
    /// the link when it is not already `.disconnected`.
    ///
    /// The waiter is removed from `pending` and resumed with `CancellationError` before this
    /// returns, so the caller unblocks while the peripheral may still be `.connecting` or
    /// `.connected`. ``ConnectCancelCoordinator`` stays set in that case. A callback that
    /// arrives with no waiter left (the connect already completed) does nothing.
    private func cancelConnect(id: UUID) {
        let request = Request.connect(id)
        guard let continuation = pending.removeValue(forKey: request) else {
            return
        }
        pendingConnect.remove(id)
        queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id),
                  peripheral.state != .disconnected
            else {
                connectCancel.clearCancelPending(id)
                return
            }
            centralManager.cancelPeripheralConnection(peripheral)
            connectCancel.markCancelPending(id)
        }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelPeripheralConnectionIfKnown(id: UUID) {
        queue.sync {
            guard let peripheral = delegateBridge.peripheral(for: id) else {
                return
            }
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// Fails every `pending` request for `id`. A pending disconnect is completed successfully
    /// when `resolvingDisconnect` is true, because that callback is the disconnect we asked
    /// for. Other requests, including an in-flight connect, receive `error`.
    private func failPendingRequests(
        for id: UUID,
        error: Error,
        resolvingDisconnect: Bool,
    ) {
        let keys = pending.keys.filter { $0.peripheralID == id }
        for key in keys {
            if key == .disconnect(id), resolvingDisconnect {
                complete(key)
            } else {
                if key == .connect(id) {
                    pendingConnect.remove(id)
                }
                complete(key, throwing: error)
            }
        }
    }

    /// Completes `.connect` only when this id is in ``pendingConnect``. A `didConnect` for an
    /// attempt that was cancelled, or that never called `CBCentralManager.connect`, is ignored.
    private func completeConnectIfCurrent(id: UUID) {
        guard pendingConnect.contains(id) else {
            return
        }
        pendingConnect.remove(id)
        complete(.connect(id))
    }

    /// Fails `.connect` only when this id is in ``pendingConnect``. A stale `didFailToConnect`
    /// after the attempt was cancelled or completed does not fail a later request.
    private func failConnectIfCurrent(id: UUID, reason: String) {
        guard pendingConnect.contains(id) else {
            return
        }
        pendingConnect.remove(id)
        complete(
            .connect(id),
            throwing: BluetoothCentralError.connectionFailed(id, reason: reason),
        )
    }

    /// Runs ``ConnectCancelCoordinator/teardownOutcome(for:snapshot:)`` for a fail or disconnect
    /// that arrived while a cancel was outstanding, and performs the cancel-again or
    /// retry-connect side effect. Returns without yielding ``CentralEvent/disconnected``; that
    /// event is for a link drop the client did not ask for.
    private func handleConnectCancelTeardown(
        id: UUID,
        peripheralState: PeripheralConnectionSnapshot,
    ) {
        let snapshot = PeripheralLinkSnapshot(peripheralState)
        switch connectCancel.teardownOutcome(for: id, snapshot: snapshot) {
        case .ignore:
            break
        case .reCancelWhilePending:
            cancelPeripheralConnectionIfKnown(id: id)
        case .clearedRetryConnect:
            issueConnectIfPending(id: id)
        }
    }

    /// Starts a connect left parked by ``connectPeripheral(id:request:)`` once cancel teardown
    /// has cleared the flag. If Bluetooth is no longer `.poweredOn`, fails that waiter with
    /// ``BluetoothCentralError/notPoweredOn`` instead of calling `connect`.
    private func issueConnectIfPending(id: UUID) {
        guard pending[.connect(id)] != nil else {
            return
        }
        guard state == .poweredOn else {
            pendingConnect.remove(id)
            complete(.connect(id), throwing: BluetoothCentralError.notPoweredOn)
            return
        }
        queue.sync {
            connectPeripheral(id: id, request: .connect(id))
        }
    }

    /// Fails every in-flight connect with ``BluetoothCentralError/notPoweredOn``. Other GATT
    /// requests are left pending; their own callbacks or a later disconnect complete them.
    /// Called only for `.poweredOff`, `.resetting`, `.unauthorized`, and `.unsupported`.
    /// `.unknown` does not fail connects.
    private func failPendingConnectsNotPoweredOn() {
        let connectKeys = pending.keys.filter {
            if case .connect = $0 { return true }
            return false
        }
        for key in connectKeys {
            if case let .connect(id) = key {
                pendingConnect.remove(id)
            }
            complete(key, throwing: BluetoothCentralError.notPoweredOn)
        }
    }

    private static func characteristic(
        on peripheral: CBPeripheral,
        serviceUUID: UUID,
        characteristicUUID: UUID,
    ) -> CBCharacteristic? {
        peripheral.services?
            .first(where: { $0.uuid.foundationUUID == serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid.foundationUUID == characteristicUUID })
    }

    /// Applies one delegate callback. This is the only writer of connection bookkeeping and the
    /// only yielder on the three broadcasters, so those streams stay in callback order.
    ///
    /// `.poweredOff`, `.resetting`, `.unauthorized`, and `.unsupported` clear every
    /// cancel-pending id and fail in-flight connects before the state is yielded. A
    /// `didFailToConnect` or `didDisconnect` whose peripheral is still `.connected`, and whose
    /// id is not pending cancel, is ignored so a stale callback cannot tear down a live link.
    /// When a cancel is pending, those two callbacks go through ``handleConnectCancelTeardown``
    /// and do not fail the replacement connect or emit ``CentralEvent/disconnected``.
    private func handle(_ event: CentralDelegateEvent) async {
        switch event {
        case let .stateUpdated(newState):
            state = newState
            if newState == .poweredOff || newState == .resetting
                || newState == .unauthorized || newState == .unsupported {
                connectCancel.clearAllCancelPending()
                failPendingConnectsNotPoweredOn()
            }
            await stateBroadcaster.yield(newState)

        case let .discovered(discovery):
            await discoveryBroadcaster.yield(discovery)

        case let .connected(id):
            switch connectCancel.connectedOutcome(for: id) {
            case .completeConnect:
                completeConnectIfCurrent(id: id)
            case .reCancelWhilePending:
                cancelPeripheralConnectionIfKnown(id: id)
            }

        case let .failedToConnect(id, reason, peripheralState):
            if connectCancel.isCancelPending(id) {
                handleConnectCancelTeardown(id: id, peripheralState: peripheralState)
                return
            }
            if peripheralState == .connected {
                return
            }
            failConnectIfCurrent(id: id, reason: reason)

        case let .disconnected(id, reason, peripheralState):
            if connectCancel.isCancelPending(id) {
                handleConnectCancelTeardown(id: id, peripheralState: peripheralState)
                return
            }
            if peripheralState == .connected {
                return
            }
            failPendingRequests(
                for: id,
                error: BluetoothCentralError.disconnected(id, reason: reason),
                resolvingDisconnect: true,
            )
            await eventsBroadcaster.yield(.disconnected(peripheralID: id))

        case let .servicesDiscovered(id, errorReason):
            complete(.discoverServices(id), id: id, errorReason: errorReason)

        case let .characteristicsDiscovered(id, errorReason):
            complete(.discoverCharacteristics(id), id: id, errorReason: errorReason)

        // A read callback both completes the pending read and is yielded. Notifications have no
        // pending read, so `complete` is a no-op and only the event is delivered. A nil service
        // UUID cannot be matched to one `Request` key, so every in-flight read of this
        // characteristic on this peripheral is failed and nothing is yielded.
        case let .characteristicValueUpdated(id, serviceUUID, characteristicUUID, value, errorReason):
            if let serviceUUID {
                let request = Request.read(id, serviceUUID, characteristicUUID)
                if let errorReason {
                    complete(request, id: id, errorReason: errorReason)
                    return
                }
                complete(request, returning: value)
                await eventsBroadcaster.yield(
                    .valueUpdated(
                        peripheralID: id,
                        serviceUUID: serviceUUID,
                        characteristicUUID: characteristicUUID,
                        value: value,
                    ),
                )
            } else {
                let error = BluetoothCentralError.connectionFailed(
                    id,
                    reason: errorReason ?? "Missing service for characteristic",
                )
                let readKeys = pending.keys.filter {
                    guard case let .read(peripheralID, _, cid) = $0 else { return false }
                    return peripheralID == id && cid == characteristicUUID
                }
                for key in readKeys {
                    complete(key, throwing: error)
                }
            }

        // ATT application errors stay numeric (`attCode`) so CSCS `0x80` / `0x81` can be mapped
        // later. Any other failure is `connectionFailed` with the bridge's reason string. A nil
        // service UUID fails every in-flight write of this characteristic on this peripheral.
        case let .characteristicWriteCompleted(id, serviceUUID, characteristicUUID, errorReason, attCode):
            if let serviceUUID {
                let request = Request.write(id, serviceUUID, characteristicUUID)
                if let attCode {
                    complete(request, throwing: BluetoothCentralError.attApplicationError(code: attCode))
                } else if let errorReason {
                    complete(
                        request,
                        throwing: BluetoothCentralError.connectionFailed(id, reason: errorReason),
                    )
                } else {
                    complete(request)
                }
                return
            }

            let error = BluetoothCentralError.connectionFailed(
                id,
                reason: errorReason ?? "Missing service for characteristic",
            )
            let writeKeys = pending.keys.filter {
                guard case let .write(peripheralID, _, cid) = $0 else { return false }
                return peripheralID == id && cid == characteristicUUID
            }
            for key in writeKeys {
                complete(key, throwing: error)
            }

        case let .notificationStateUpdated(id, serviceUUID, characteristicUUID, errorReason):
            if let serviceUUID {
                complete(.setNotify(id, serviceUUID, characteristicUUID), id: id, errorReason: errorReason)
            } else {
                let error = BluetoothCentralError.connectionFailed(
                    id,
                    reason: errorReason ?? "Missing service for characteristic",
                )
                let notifyKeys = pending.keys.filter {
                    guard case let .setNotify(peripheralID, _, cid) = $0 else { return false }
                    return peripheralID == id && cid == characteristicUUID
                }
                for key in notifyKeys {
                    complete(key, throwing: error)
                }
            }
        }
    }
}

/// Identity of one in-flight central call. See `pending` on ``CoreBluetoothCentral``.
private enum Request: Hashable {
    case connect(UUID)
    case disconnect(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID)
    case read(UUID, UUID, UUID)
    case write(UUID, UUID, UUID)
    case setNotify(UUID, UUID, UUID)

    var peripheralID: UUID {
        switch self {
        case let .connect(id),
             let .disconnect(id),
             let .discoverServices(id),
             let .discoverCharacteristics(id):
            id
        case let .read(id, _, _),
             let .write(id, _, _),
             let .setNotify(id, _, _):
            id
        }
    }

    /// Every duplicate key uses ``BluetoothCentralError/connectionFailed``. There is no separate
    /// busy error at this layer; ``DiscoveredSensor/connect()`` and ``ControlPoint`` map it on
    /// the way out.
    var duplicateInProgressError: BluetoothCentralError {
        .connectionFailed(peripheralID, reason: "Request already in progress")
    }
}

private extension PeripheralLinkSnapshot {
    init(_ snapshot: PeripheralConnectionSnapshot) {
        switch snapshot {
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .disconnecting:
            self = .disconnecting
        }
    }
}

/// `CBPeripheral.state` captured on `queue` inside the delegate callback, so ``handle(_:)``
/// can pass a ``PeripheralLinkSnapshot`` to ``ConnectCancelCoordinator`` without touching
/// CoreBluetooth off that queue. An `@unknown` future state is treated as `.disconnected`.
private enum PeripheralConnectionSnapshot: Sendable {
    case connected
    case disconnected
    case connecting
    case disconnecting

    init(_ state: CBPeripheralState) {
        switch state {
        case .connected:
            self = .connected
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .disconnected
        }
    }
}

/// What ``CentralDelegateBridge`` can observe, as `Sendable` values with no CoreBluetooth
/// types. One task delivers these to ``CoreBluetoothCentral/handle(_:)`` in yield order.
private enum CentralDelegateEvent: Sendable {
    case stateUpdated(BluetoothState)
    case discovered(DiscoveredPeripheral)
    case connected(id: UUID)
    case failedToConnect(id: UUID, reason: String, peripheralState: PeripheralConnectionSnapshot)
    case disconnected(id: UUID, reason: String?, peripheralState: PeripheralConnectionSnapshot)
    case servicesDiscovered(id: UUID, errorReason: String?)
    case characteristicsDiscovered(id: UUID, errorReason: String?)
    case characteristicValueUpdated(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        value: Data,
        errorReason: String?,
    )
    case characteristicWriteCompleted(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        errorReason: String?,
        attCode: UInt8?,
    )
    case notificationStateUpdated(
        id: UUID,
        serviceUUID: UUID?,
        characteristicUUID: UUID,
        errorReason: String?,
    )
}

/// `CBCentralManager` / `CBPeripheral` delegate. Callbacks run on the central's serial queue.
///
/// The peripheral map is lock-protected because actor methods read it from `queue.sync` and
/// discovery writes it from the delegate callback on that same queue; the lock covers reads
/// that happen off the queue as well (`peripheral(for:)` from the actor before `sync`).
/// Events are yielded onto the FIFO stream and not applied here. The bridge retains discovered
/// peripherals so CoreBluetooth does not drop them before connect.
///
/// Failure callbacks copy CoreBluetooth's error text into a reason string. ATT write errors in
/// the ATT domain keep the numeric code when it fits in `UInt8` and is not success, so CSC
/// application errors survive. A write whose characteristic has no service UUID, and no other
/// error, is reported as `"Missing service for characteristic"`.
private final class CentralDelegateBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let lock = NSLock()
    private let events: AsyncStream<CentralDelegateEvent>.Continuation
    private var peripherals: [UUID: CBPeripheral] = [:]

    init(events: AsyncStream<CentralDelegateEvent>.Continuation) {
        self.events = events
    }

    func peripheral(for id: UUID) -> CBPeripheral? {
        lock.lock()
        defer { lock.unlock() }
        return peripherals[id]
    }

    private func emit(_ event: CentralDelegateEvent) {
        events.yield(event)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        emit(.stateUpdated(BluetoothState(central.state)))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
    ) {
        let id = peripheral.identifier
        lock.lock()
        peripheral.delegate = self
        peripherals[id] = peripheral
        lock.unlock()

        emit(
            .discovered(
                Self.discoveredPeripheral(peripheral: peripheral, advertisementData: advertisementData),
            ),
        )
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        emit(.connected(id: peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?,
    ) {
        emit(
            .failedToConnect(
                id: peripheral.identifier,
                reason: error?.localizedDescription ?? "Connection failed",
                peripheralState: PeripheralConnectionSnapshot(peripheral.state),
            ),
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?,
    ) {
        emit(
            .disconnected(
                id: peripheral.identifier,
                reason: error?.localizedDescription,
                peripheralState: PeripheralConnectionSnapshot(peripheral.state),
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        emit(.servicesDiscovered(id: peripheral.identifier, errorReason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        emit(.characteristicsDiscovered(id: peripheral.identifier, errorReason: error?.localizedDescription))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }
        emit(
            .characteristicValueUpdated(
                id: peripheral.identifier,
                serviceUUID: characteristic.service?.uuid.foundationUUID,
                characteristicUUID: characteristicUUID,
                value: characteristic.value ?? Data(),
                errorReason: error?.localizedDescription,
            ),
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }

        var attCode: UInt8?
        var errorReason: String?
        if let error = error as NSError? {
            if error.domain == CBATTErrorDomain {
                let code = error.code
                if code != CBATTError.success.rawValue {
                    if let attCodeValue = UInt8(exactly: code) {
                        attCode = attCodeValue
                    } else {
                        errorReason = error.localizedDescription
                    }
                }
            } else {
                errorReason = error.localizedDescription
            }
        }

        let serviceUUID = characteristic.service?.uuid.foundationUUID
        if serviceUUID == nil, errorReason == nil, attCode == nil {
            errorReason = "Missing service for characteristic"
        }

        emit(
            .characteristicWriteCompleted(
                id: peripheral.identifier,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                errorReason: errorReason,
                attCode: attCode,
            ),
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?,
    ) {
        guard let characteristicUUID = characteristic.uuid.foundationUUID else { return }
        emit(
            .notificationStateUpdated(
                id: peripheral.identifier,
                serviceUUID: characteristic.service?.uuid.foundationUUID,
                characteristicUUID: characteristicUUID,
                errorReason: error?.localizedDescription,
            ),
        )
    }

    private static func discoveredPeripheral(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
    ) -> DiscoveredPeripheral {
        DiscoveredPeripheral(
            id: peripheral.identifier,
            name: peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
            serviceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
                .compactMap(\.foundationUUID) ?? [],
        )
    }
}

private extension BluetoothState {
    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

private extension UUID {
    var cbUUID: CBUUID { CBUUID(nsuuid: self) }
}

/// Expands 16-bit and 32-bit `CBUUID` strings to the Bluetooth base UUID
/// `0000xxxx-0000-1000-8000-00805F9B34FB` (32-bit keeps all eight hex digits). 128-bit strings
/// pass through. A string `UUID` rejects becomes `nil`, and that characteristic callback is
/// dropped.
private extension CBUUID {
    var foundationUUID: UUID? {
        let uuidString = uuidString
        if uuidString.count == 4 {
            return UUID(uuidString: "0000\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        if uuidString.count == 8 {
            return UUID(uuidString: "\(uuidString)-0000-1000-8000-00805F9B34FB")
        }
        return UUID(uuidString: uuidString)
    }
}
#endif
