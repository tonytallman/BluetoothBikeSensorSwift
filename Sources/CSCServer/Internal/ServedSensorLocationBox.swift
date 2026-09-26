import Foundation

final class ServedSensorLocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kind: SensorLocationKind

    init(initial: SensorLocationKind) {
        kind = initial
    }

    func read() -> SensorLocationKind {
        lock.lock()
        defer { lock.unlock() }
        return kind
    }

    func store(_ newKind: SensorLocationKind) {
        lock.lock()
        defer { lock.unlock() }
        kind = newKind
    }
}
