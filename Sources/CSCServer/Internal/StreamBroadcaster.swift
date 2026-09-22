import Foundation

/// Multicast fan-out to many `AsyncStream` subscribers, backed by an actor.
///
/// Used by production and fake peripherals. `onTermination` cannot `await`, so unsubscribe
/// uses `Task { await remove(id) }` — a cancelled stream may receive one more event.
actor StreamBroadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    func makeStream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        continuations[id] = continuation

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task {
                await self.remove(id)
            }
        }

        return stream
    }

    func yield(_ value: Element) {
        let active = Array(continuations.values)
        for continuation in active {
            continuation.yield(value)
        }
    }

    func finish() {
        let active = Array(continuations.values)
        continuations.removeAll()
        for continuation in active {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
