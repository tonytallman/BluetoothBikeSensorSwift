import Foundation

final class ServedSensorLocationBox: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var kind: SensorLocationKind

    init(initial: SensorLocationKind) {
        kind = initial
    }

    func read() -> SensorLocationKind {
        lock.withLock { kind }
    }

    func store(_ newKind: SensorLocationKind) {
        lock.withLock { kind = newKind }
    }
}
