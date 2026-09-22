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

    @Test func addRemoveAndRemoveAllAreRecorded() async throws {
        let fake = FakeBluetoothPeripheral()
        let service = Self.sampleService()

        try await fake.add(service)
        try await fake.removeService(uuid: service.uuid)
        await fake.removeAllServices()

        let calls = await fake.recordedCalls
        #expect(calls == [
            .add(service),
            .removeService(uuid: service.uuid),
            .removeAllServices,
        ])
    }

    @Test func conflictingPropertiesThrowAndRecordNothing() async {
        let fake = FakeBluetoothPeripheral()
        let writeAndWriteWithoutResponse = PeripheralService(
            uuid: UUID(),
            isPrimary: true,
            characteristics: [
                PeripheralCharacteristic(
                    uuid: UUID(),
                    properties: [.write, .writeWithoutResponse],
                    permissions: [.writeable],
                    value: nil,
                ),
            ],
        )
        let notifyAndIndicate = PeripheralService(
            uuid: UUID(),
            isPrimary: true,
            characteristics: [
                PeripheralCharacteristic(
                    uuid: UUID(),
                    properties: [.notify, .indicate],
                    permissions: [.readable],
                    value: nil,
                ),
            ],
        )

        await #expect(throws: BluetoothPeripheralError.conflictingProperties) {
            try await fake.add(writeAndWriteWithoutResponse)
        }
        await #expect(throws: BluetoothPeripheralError.conflictingProperties) {
            try await fake.add(notifyAndIndicate)
        }
        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func cachedValueRejectsInvalidCombinations() async {
        let fake = FakeBluetoothPeripheral()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let cachedValue = Data([0x01])

        let invalidPropertySets: [CharacteristicProperties] = [
            [.notify],
            [.indicate],
            [.write],
            [.writeWithoutResponse],
            [],
        ]

        for properties in invalidPropertySets {
            let service = PeripheralService(
                uuid: serviceUUID,
                isPrimary: true,
                characteristics: [
                    PeripheralCharacteristic(
                        uuid: characteristicUUID,
                        properties: properties,
                        permissions: [.readable],
                        value: cachedValue,
                    ),
                ],
            )
            await #expect(throws: BluetoothPeripheralError.cachedValueNotReadOnly) {
                try await fake.add(service)
            }
        }

        let writeableService = PeripheralService(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                PeripheralCharacteristic(
                    uuid: characteristicUUID,
                    properties: [.read],
                    permissions: [.writeable],
                    value: cachedValue,
                ),
            ],
        )
        await #expect(throws: BluetoothPeripheralError.cachedValueNotReadOnly) {
            try await fake.add(writeableService)
        }

        #expect(await fake.recordedCalls.isEmpty)
    }

    @Test func cachedReadOnlyValueIsRecordedAndStillRequiresEmitRead() async throws {
        let fake = FakeBluetoothPeripheral()
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let cachedValue = Data([0x01, 0x02])
        let service = PeripheralService(
            uuid: serviceUUID,
            isPrimary: true,
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

        let stream = await fake.readRequests
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
        let read = await iterator.next()
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
        let advertisement = Advertisement(localName: "Test", serviceUUIDs: [UUID()])

        #expect(await fake.isAdvertising == false)
        try await fake.startAdvertising(advertisement)
        #expect(await fake.isAdvertising == true)

        await fake.stopAdvertising()
        #expect(await fake.isAdvertising == false)

        await fake.failNextAdvertise()
        await #expect(throws: BluetoothPeripheralError.advertisingFailed(reason: "Test failure")) {
            try await fake.startAdvertising(advertisement)
        }
        #expect(await fake.isAdvertising == false)

        let calls = await fake.recordedCalls
        #expect(calls == [
            .startAdvertising(advertisement),
            .stopAdvertising,
            .startAdvertising(advertisement),
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
        let stream = await fake.readRequests
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

        let read = await iterator.next()
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
        _ = await iterator.next()

        await #expect(throws: BluetoothPeripheralError.missingReadValue) {
            try await fake.respond(to: missingValueID, with: .success, value: nil)
        }

        let callsAfterMissingValue = await fake.recordedCalls
        #expect(callsAfterMissingValue == [
            .respond(id: requestID, result: .success, value: payload),
        ])

        await #expect(throws: BluetoothPeripheralError.unknownRequest) {
            try await fake.respond(to: requestID, with: .success, value: payload)
        }
    }

    @Test func writeRoundTripUsesSingleRespond() async throws {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.writeTransactions
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
        let received = await iterator.next()
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
        _ = await iterator.next()

        await #expect(throws: BluetoothPeripheralError.unexpectedResponseValue) {
            try await fake.respond(to: outstandingID, with: .success, value: Data([0x01]))
        }
        #expect(await fake.recordedCalls == [
            .respond(id: transactionID, result: .error(code: 0x80), value: nil),
        ])
    }

    @Test func subscriptionChangesYieldSubscribedThenUnsubscribed() async {
        let fake = FakeBluetoothPeripheral()
        let stream = await fake.subscriptionChanges
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
        #expect(subscribed == .subscribed(
            centralID: centralID,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        ))
        #expect(unsubscribed == .unsubscribed(
            centralID: centralID,
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
        ))
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

        let readyStream = await fake.subscriberUpdatesReady
        var readyIterator = readyStream.makeAsyncIterator()
        await fake.emitReadyToUpdateSubscribers()
        #expect(await readyIterator.next() != nil)

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
                centralIDs: .all,
            ),
        ))
        #expect(calls.contains(
            .updateValue(
                value: value,
                serviceUUID: service.uuid,
                characteristicUUID: characteristicUUID,
                centralIDs: .only(centralIDs),
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

    private static func sampleService(notifyCharacteristic: Bool = false) -> PeripheralService {
        PeripheralService(
            uuid: UUID(),
            isPrimary: true,
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
