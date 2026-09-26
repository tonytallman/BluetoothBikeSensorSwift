import Foundation

/// Holds the sensor location currently served on `0x2A5D` for a multiple-location build.
///
/// Created once by `ServerRuntime` and handed to every `ServerSession` across `stop()`/`start()`
/// cycles, so the served byte survives session restarts even though the build-time
/// `Server.location` snapshot does not change. A plain lock (not an actor) because
/// `ServerSession.readResponse(for:)` reads it synchronously while answering a GATT read, and
/// `ServerRuntime` is a different actor from `ServerSession`.
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
