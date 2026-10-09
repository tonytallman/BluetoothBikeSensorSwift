import Foundation

/// Process-wide monotonic ids for one ``Scanner/scan()`` session.
///
/// ``CoreBluetoothCentral`` orders `startScanning` against `stopScanning` with these values.
/// `issue()` runs in the `AsyncStream` factory, which is not isolated to the central, and the
/// id has to exist before either call. An `NSLock` is enough: the values only need to increase.
/// They are not per central, so two centrals never reuse an id either. Wrapping is not handled;
/// `UInt64` sessions will not wrap in practice.
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
