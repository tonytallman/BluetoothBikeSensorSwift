import Foundation

/// Multicast fan-out to many `AsyncStream` subscribers, backed by an actor.
///
/// Used by production and fake centrals. `onTermination` cannot `await`, so unsubscribe
/// uses `Task { await remove(id) }` — a cancelled stream may receive one more event.
actor StreamBroadcaster<Element: Sendable> {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var finished = false

    func makeStream() -> AsyncStream<Element> {
        if finished {
            let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
            continuation.finish()
            return stream
        }

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

    /// Finishes every current subscriber. A later ``makeStream()`` returns an already-finished
    /// stream, which is how a speed or cadence subscription taken after disconnect ends
    /// immediately. A second call does nothing. ``yield(_:)`` after this drops the value
    /// because the subscriber map is empty.
    func finish() {
        guard !finished else {
            return
        }
        finished = true
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
