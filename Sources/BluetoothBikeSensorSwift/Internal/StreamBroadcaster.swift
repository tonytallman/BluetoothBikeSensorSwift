import Foundation

enum StreamBroadcaster<Element: Sendable>: Sendable {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

        func makeStream() -> AsyncStream<Element> {
            AsyncStream { continuation in
                let id = UUID()
                lock.lock()
                continuations[id] = continuation
                lock.unlock()

                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    lock.lock()
                    continuations.removeValue(forKey: id)
                    lock.unlock()
                }
            }
        }

        func yield(_ value: Element) {
            lock.lock()
            let active = Array(continuations.values)
            lock.unlock()
            for continuation in active {
                continuation.yield(value)
            }
        }

        func finish() {
            lock.lock()
            let active = Array(continuations.values)
            continuations.removeAll()
            lock.unlock()
            for continuation in active {
                continuation.finish()
            }
        }
    }
}
