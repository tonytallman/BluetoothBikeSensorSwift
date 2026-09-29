import Foundation

package enum ScanSessionID {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var next: UInt64 = 0

    package static func issue() -> UInt64 {
        lock.withLock {
            next += 1
            return next
        }
    }
}
