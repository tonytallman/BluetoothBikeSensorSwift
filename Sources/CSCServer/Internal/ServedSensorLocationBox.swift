import Foundation
import os

final class ServedSensorLocationBox: @unchecked Sendable {
    private let kind: OSAllocatedUnfairLock<SensorLocationKind>

    init(initial: SensorLocationKind) {
        kind = OSAllocatedUnfairLock(initialState: initial)
    }

    func read() -> SensorLocationKind {
        kind.withLock { $0 }
    }

    func store(_ newKind: SensorLocationKind) {
        kind.withLock { $0 = newKind }
    }
}
