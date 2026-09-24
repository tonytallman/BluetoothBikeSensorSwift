import CSCServer
import Foundation
@testable import SampleServerApp

final class FakeSensorServerFactory: SensorServerFactory, @unchecked Sendable {
    struct Record: Sendable {
        let revolutions: RevolutionInputs
        let location: LocationInput
    }

    private let lock = NSLock()
    private let slot: FakeLiveServerSlot
    private let subscriberCounts: FakeMeasurementSubscriberCount
    private var scripts: [FakeSensorServer.Script]
    private(set) var records: [Record] = []
    private(set) var servers: [FakeSensorServer] = []

    init(
        slot: FakeLiveServerSlot,
        scripts: [FakeSensorServer.Script],
        subscriberCounts: FakeMeasurementSubscriberCount = FakeMeasurementSubscriberCount(),
    ) {
        self.slot = slot
        self.scripts = scripts
        self.subscriberCounts = subscriberCounts
    }

    func makeServer(revolutions: RevolutionInputs, location: LocationInput) -> any SensorServer {
        lock.lock()
        let script = scripts.isEmpty ? .succeed : scripts.removeFirst()
        records.append(Record(revolutions: revolutions, location: location))
        let server = FakeSensorServer(
            slot: slot,
            script: script,
            subscriberCounts: subscriberCounts,
        )
        servers.append(server)
        lock.unlock()
        return server
    }

    func recordCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return records.count
    }

    func multipleHandler(at index: Int) -> SensorLocationsHandler? {
        lock.lock()
        defer { lock.unlock() }
        guard records.indices.contains(index),
              case let .multiple(delegate) = records[index].location,
              let handler = delegate as? SensorLocationsHandler else {
            return nil
        }
        return handler
    }

    func cumulativeHandler(at index: Int) -> CumulativeWheelRevolutionsHandler? {
        lock.lock()
        defer { lock.unlock() }
        guard records.indices.contains(index) else { return nil }
        switch records[index].revolutions {
        case let .wheel(_, handler):
            return handler as? CumulativeWheelRevolutionsHandler
        case let .wheelAndCrank(_, handler, _):
            return handler as? CumulativeWheelRevolutionsHandler
        case .crank:
            return nil
        }
    }
}
