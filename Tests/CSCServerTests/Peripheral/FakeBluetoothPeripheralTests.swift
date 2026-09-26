import CSCServer
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct FakeBluetoothPeripheralTests {
    @Test func stateFollowsInitAndSetState() async {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOff)
        #expect(await fake.currentState == .poweredOff)

        await fake.setState(.poweredOn)
        #expect(await fake.currentState == .poweredOn)
    }

    @Test func stateUpdatesYieldsNextState() async {
        let fake = FakeBluetoothPeripheral(initialState: .poweredOff)
        let stream = await fake.stateUpdates
        var iterator = stream.makeAsyncIterator()

        await fake.setState(.poweredOn)
        let next = await iterator.next()
        #expect(next == .poweredOn)
    }

    @Test func addAndRemoveAreRecorded() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()

        try await fake.add(service)
        try await fake.removeService(uuid: service.uuid)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .add(service),
            .removeService(uuid: service.uuid),
        ])
    }

    @Test func cachedReadOnlyValueIsRecordedAndStillRequiresEmitRead() async throws {
        let fake = FakeBluetoothPeripheral()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let cachedValue = Data([0x01, 0x02])
        let service = PeripheralService(
            uuid: serviceUUID,
                        characteristics: [
                PeripheralCharacteristic(
                    uuid: characteristicUUID,
                    properties: [.read],
                    permissions: [.readable],
                    value: cachedValue,
                ),
            ],
        )

        try await fake.add(service)
        #expect(await fake.recordedCalls == [.add(service)])

        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()
        let requestID = UUID()
        let centralID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 0,
            ),
        )
        let read = Self.readRequest(await iterator.next())
        #expect(read?.id == requestID)
        #expect(read?.offset == 0)
    }

    @Test func removeUnknownServiceThrowsWithoutRecording() async {
        let fake = FakeBluetoothPeripheral()
        let unknownUUID = UUID()

        await #expect(throws: BluetoothPeripheralError.serviceNotFound) {
            try await fake.removeService(uuid: unknownUUID)
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func advertiseStopAndFailNextAdvertise() async throws {
        let fake = FakeBluetoothPeripheral()
        let serviceUUIDs = [UUID()]

        #expect(await fake.isAdvertising == false)
        try await fake.startAdvertising(serviceUUIDs: serviceUUIDs)
        #expect(await fake.isAdvertising == true)

        await fake.stopAdvertising()
        #expect(await fake.isAdvertising == false)

        await fake.failNextAdvertise()
        await #expect(throws: BluetoothPeripheralError.advertisingFailed(reason: "Test failure")) {
            try await fake.startAdvertising(serviceUUIDs: serviceUUIDs)
        }
        #expect(await fake.isAdvertising == false)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .startAdvertising(serviceUUIDs: serviceUUIDs),
            .stopAdvertising,
            .startAdvertising(serviceUUIDs: serviceUUIDs),
        ])
    }

    @Test func failNextAddRecordsAddAndLeavesServiceAbsent() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()

        await fake.failNextAdd()
        await #expect(throws: BluetoothPeripheralError.addServiceFailed(serviceUUID: service.uuid, reason: "Test failure")) {
            try await fake.add(service)
        }
        #expect(await fake.recordedCalls == [.add(service)])

        await #expect(throws: BluetoothPeripheralError.serviceNotFound) {
            try await fake.removeService(uuid: service.uuid)
        }
    }

    @Test func readRoundTripAndRespondValidation() async throws {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()

        let requestID = UUID()
        let centralID = UUID()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 3,
            ),
        )

        let read = Self.readRequest(await iterator.next())
        #expect(read?.id == requestID)
        #expect(read?.offset == 3)

        let payload = Data([0xAA, 0xBB])
        try await fake.respond(to: requestID, with: .success, value: payload)

        let missingValueID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: missingValueID,
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 0,
            ),
        )
        #expect(Self.readRequest(await iterator.next())?.id == missingValueID)

        try await fake.respond(to: missingValueID, with: .success, value: nil)

        let callsAfterMissingValue = await fake.recordedCalls
        #expect(callsAfterMissingValue == [
            .respond(id: requestID, result: .success, value: payload),
            .respond(id: missingValueID, result: .success, value: nil),
        ])

        await #expect(throws: BluetoothPeripheralError.unknownRequest) {
            try await fake.respond(to: requestID, with: .success, value: payload)
        }
    }

    @Test func emptyReadSuccessIsAccepted() async throws {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()

        let requestID = UUID()
        let centralID = UUID()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()

        await fake.emitRead(
            PeripheralReadRequest(
                id: requestID,
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 0,
            ),
        )
        #expect(Self.readRequest(await iterator.next())?.id == requestID)

        let nilRequestID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: nilRequestID,
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
                offset: 0,
            ),
        )
        #expect(Self.readRequest(await iterator.next())?.id == nilRequestID)

        try await fake.respond(to: nilRequestID, with: .success, value: nil)

        try await fake.respond(to: requestID, with: .success, value: Data())
        #expect(await fake.recordedCalls == [
            .respond(id: nilRequestID, result: .success, value: nil),
            .respond(id: requestID, result: .success, value: Data()),
        ])

        await #expect(throws: BluetoothPeripheralError.unknownRequest) {
            try await fake.respond(to: requestID, with: .success, value: Data())
        }
    }

    @Test func writeRoundTripUsesSingleRespond() async throws {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()

        let centralID = UUID()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let transactionID = UUID()
        let transaction = PeripheralWriteTransaction(
            id: transactionID,
            requests: [
                PeripheralWriteRequest(
                    centralID: centralID,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    offset: 0,
                    value: Data([0x01]),
                ),
                PeripheralWriteRequest(
                    centralID: centralID,
                    serviceUUID: serviceUUID,
                    characteristicUUID: characteristicUUID,
                    offset: 1,
                    value: Data([0x02]),
                ),
            ],
        )

        await fake.emitWriteTransaction(transaction)
        let received = Self.writeTransaction(await iterator.next())
        #expect(received?.id == transactionID)
        #expect(received?.requests.count == 2)

        try await fake.respond(to: transactionID, with: .error(code: 0x80), value: nil)
        #expect(await fake.recordedCalls == [
            .respond(id: transactionID, result: .error(code: 0x80), value: nil),
        ])

        let outstandingID = UUID()
        await fake.emitWriteTransaction(
            PeripheralWriteTransaction(
                id: outstandingID,
                requests: [
                    PeripheralWriteRequest(
                        centralID: centralID,
                        serviceUUID: serviceUUID,
                        characteristicUUID: characteristicUUID,
                        offset: 0,
                        value: Data([0x03]),
                    ),
                ],
            ),
        )
        #expect(Self.writeTransaction(await iterator.next())?.id == outstandingID)

        try await fake.respond(to: outstandingID, with: .success, value: Data([0x01]))
        #expect(await fake.recordedCalls == [
            .respond(id: transactionID, result: .error(code: 0x80), value: nil),
            .respond(id: outstandingID, result: .success, value: Data([0x01])),
        ])
    }

    @Test func eventsYieldSubscribedThenUnsubscribed() async {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()

        let centralID = UUID()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()

        await fake.emitSubscription(
            .subscribed(
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            ),
        )
        await fake.emitSubscription(
            .unsubscribed(
                centralID: centralID,
                serviceUUID: serviceUUID,
                characteristicUUID: characteristicUUID,
            ),
        )

        let subscribed = await iterator.next()
        let unsubscribed = await iterator.next()
        #expect(subscribed == .subscription(.subscribed(
            centralID: centralID,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        )))
        #expect(unsubscribed == .subscription(.unsubscribed(
            centralID: centralID,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        )))
    }

    @Test func eventsPreserveEmitOrderAcrossKinds() async {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.events
        var iterator = stream.makeAsyncIterator()

        let read = PeripheralReadRequest(
            id: UUID(),
            centralID: UUID(),
            serviceUUID: UUID(),
            characteristicUUID: UUID(),
            offset: 0,
        )
        let subscription = SubscriptionChange.subscribed(
            centralID: UUID(),
            serviceUUID: UUID(),
            characteristicUUID: UUID(),
        )
        let write = PeripheralWriteTransaction(id: UUID(), requests: [])

        await fake.emitRead(read)
        await fake.emitSubscription(subscription)
        await fake.emitWriteTransaction(write)
        await fake.emitReadyToUpdateSubscribers()
        await fake.setState(.poweredOff)

        var received: [PeripheralEvent] = []
        for _ in 0..<5 {
            if let event = await iterator.next() {
                received.append(event)
            }
        }
        #expect(received == [
            .read(read),
            .subscription(subscription),
            .writeTransaction(write),
            .readyToUpdateSubscribers,
            .stateUpdated(.poweredOff),
        ])
    }

    @Test func poweredOnGuardsThrowWithoutRecording() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService(notifyCharacteristic: true)
        try await fake.add(service)
        let readID = UUID()
        await fake.emitRead(
            PeripheralReadRequest(
                id: readID,
                centralID: UUID(),
                serviceUUID: service.uuid,
                characteristicUUID: service.characteristics[0].uuid,
                offset: 0,
            ),
        )
        await fake.setState(.poweredOff)
        let callsBefore = await fake.recordedCalls

        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await fake.add(Self.sampleService())
        }
        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await fake.startAdvertising(serviceUUIDs: [])
        }
        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await fake.updateValue(
                Data([0x01]),
                serviceUUID: service.uuid,
                characteristicUUID: service.characteristics[0].uuid,
                onSubscribedCentrals: nil,
            )
        }
        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await fake.respond(to: readID, with: .success, value: Data([0x01]))
        }
        #expect(await fake.recordedCalls == callsBefore)
        #expect(await fake.isAdvertising == false)

        await fake.stopAdvertising()
        try await fake.removeService(uuid: service.uuid)
        #expect(await fake.recordedCalls == callsBefore + [
            .stopAdvertising,
            .removeService(uuid: service.uuid),
        ])
    }

    @Test func leavingPoweredOnStopsAdvertisingAndCountsLoss() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()
        try await fake.add(service)
        try await fake.startAdvertising(serviceUUIDs: [service.uuid])
        #expect(await fake.powerLossCount == 0)

        await fake.setState(.poweredOn)
        #expect(await fake.powerLossCount == 0)
        #expect(await fake.isAdvertising)

        await fake.setState(.resetting)
        #expect(await fake.powerLossCount == 1)
        #expect(await fake.isAdvertising == false)

        await fake.setState(.poweredOff)
        #expect(await fake.powerLossCount == 2)

        await fake.setState(.poweredOn)
        #expect(await fake.powerLossCount == 2)
        try await fake.removeService(uuid: service.uuid)
    }

    @Test func heldCallsRecheckPowerOnRelease() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()
        let serviceUUIDs = [service.uuid]

        await fake.holdNextAdd()
        let offAdd = Task { try await fake.add(service) }
        await fake.waitUntilAddHeld()
        await fake.setState(.poweredOff)
        await fake.releaseAdd()
        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await offAdd.value
        }

        await fake.setState(.poweredOn)
        await fake.holdNextAdvertise()
        let offAdvertise = Task { try await fake.startAdvertising(serviceUUIDs: serviceUUIDs) }
        await fake.waitUntilAdvertiseHeld()
        await fake.setState(.poweredOff)
        await fake.releaseAdvertise()
        await #expect(throws: BluetoothPeripheralError.notPoweredOn) {
            try await offAdvertise.value
        }
        #expect(await fake.recordedCalls.isEmpty)

        await fake.setState(.poweredOn)
        await fake.holdNextAdd()
        let onAdd = Task { try await fake.add(service) }
        await fake.waitUntilAddHeld()
        #expect(await fake.recordedCalls.isEmpty)
        await fake.releaseAdd()
        try await onAdd.value

        await fake.holdNextAdvertise()
        let onAdvertise = Task { try await fake.startAdvertising(serviceUUIDs: serviceUUIDs) }
        await fake.waitUntilAdvertiseHeld()
        await fake.releaseAdvertise()
        try await onAdvertise.value

        #expect(await fake.recordedCalls == [.add(service), .startAdvertising(serviceUUIDs: serviceUUIDs)])
        #expect(await fake.isAdvertising)
    }

    @Test func heldUpdateValueRecordsBeforeParkAndReturnsAcceptedAtRelease() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService(notifyCharacteristic: true)
        try await fake.add(service)
        let characteristicUUID = service.characteristics[0].uuid
        let value = Data([0x10])

        await fake.holdNextUpdateValue()
        let update = Task {
            try await fake.updateValue(
                value,
                serviceUUID: service.uuid,
                characteristicUUID: characteristicUUID,
                onSubscribedCentrals: nil,
            )
        }
        await fake.waitUntilUpdateValueHeld()
        let expectedCall = FakeBluetoothPeripheral.RecordedCall.updateValue(
            value: value,
            serviceUUID: service.uuid,
            characteristicUUID: characteristicUUID,
            onSubscribedCentrals: nil,
        )
        #expect(await fake.recordedCalls == [.add(service), expectedCall])

        await fake.setNextUpdateValueAccepted(false)
        await fake.releaseUpdateValue()
        #expect(try await update.value == false)
    }

    @Test func notifyBackpressureAndCentralFilters() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService(notifyCharacteristic: true)
        try await fake.add(service)

        let characteristicUUID = service.characteristics[0].uuid
        let value = Data([0x10])

        let accepted = try await fake.updateValue(
            value,
            serviceUUID: service.uuid,
            characteristicUUID: characteristicUUID,
            onSubscribedCentrals: nil,
        )
        #expect(accepted == true)

        await fake.setNextUpdateValueAccepted(false)
        let rejected = try await fake.updateValue(
            value,
            serviceUUID: service.uuid,
            characteristicUUID: characteristicUUID,
            onSubscribedCentrals: nil,
        )
        #expect(rejected == false)

        let eventStream = await fake.events
        var eventIterator = eventStream.makeAsyncIterator()
        await fake.emitReadyToUpdateSubscribers()
        #expect(await eventIterator.next() == .readyToUpdateSubscribers)

        let centralIDs = [UUID(), UUID()]
        _ = try await fake.updateValue(
            value,
            serviceUUID: service.uuid,
            characteristicUUID: characteristicUUID,
            onSubscribedCentrals: centralIDs,
        )

        let calls = await fake.recordedCalls
        #expect(calls.contains(
            .updateValue(
                value: value,
                serviceUUID: service.uuid,
                characteristicUUID: characteristicUUID,
                onSubscribedCentrals: nil,
            ),
        ))
        #expect(calls.contains(
            .updateValue(
                value: value,
                serviceUUID: service.uuid,
                characteristicUUID: characteristicUUID,
                onSubscribedCentrals: centralIDs,
            ),
        ))
    }

    @Test func updateValueThrowsWhenCharacteristicMissing() async {
        let fake = FakeBluetoothPeripheral()

        await #expect(throws: BluetoothPeripheralError.characteristicNotFound) {
            try await fake.updateValue(
                Data([0x01]),
                serviceUUID: UUID(),
                characteristicUUID: UUID(),
                onSubscribedCentrals: nil,
            )
        }
    }

    @Test func waitForRecordedCallResumesWhenMatchingCallAppears() async {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()

        let waiter = Task {
            await fake.waitForRecordedCall { call in
                if case .add = call { return true }
                return false
            }
        }

        try? await fake.add(service)
        await waiter.value
    }

    @Test func waitForStateUpdatesSubscriberResumesWhenStreamRequested() async {
        let fake = FakeBluetoothPeripheral(initialState: .unknown)

        let waiter = Task {
            await fake.waitForStateUpdatesSubscriber()
        }

        _ = await fake.stateUpdates
        await waiter.value
    }

    private static func readRequest(_ event: PeripheralEvent?) -> PeripheralReadRequest? {
        if case let .read(request) = event {
            return request
        }
        return nil
    }

    private static func writeTransaction(_ event: PeripheralEvent?) -> PeripheralWriteTransaction? {
        if case let .writeTransaction(transaction) = event {
            return transaction
        }
        return nil
    }

    private static func sampleService(notifyCharacteristic: Bool = false) -> PeripheralService {
        PeripheralService(
            uuid: UUID(),
                        characteristics: [
                PeripheralCharacteristic(
                    uuid: UUID(),
                    properties: notifyCharacteristic ? [.notify] : [.read],
                    permissions: [.readable],
                    value: nil,
                ),
            ],
        )
    }
}
