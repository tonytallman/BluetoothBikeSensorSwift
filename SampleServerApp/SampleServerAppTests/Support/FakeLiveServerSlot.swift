import CSCServer
import Foundation

final class FakeLiveServerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false

    var isOccupied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return occupied
    }

    func claim() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !occupied else {
            throw ServerError.alreadyStarted
        }
        occupied = true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        occupied = false
    }
}
