import Foundation

/// Holds the sensor location currently served on `0x2A5D` for a multiple-location build.
///
/// Created once by `ServerLifecycle` and handed to every `ServerSession` across `stop()`/
/// `start()` cycles, so the served byte survives session restarts even though the build-time
/// location snapshot does not change. A plain lock (not an actor) because
/// `ServerSession.readResponse(for:)` reads it synchronously while answering a GATT read, and
/// `ServerLifecycle` is a different actor from `ServerSession`. `kind` is safe to mutate from any
/// thread because every access goes through `lock`; `nonisolated(unsafe)` tells the compiler to
/// trust that manual synchronization instead of rejecting a mutable var in a `Sendable` class.
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
