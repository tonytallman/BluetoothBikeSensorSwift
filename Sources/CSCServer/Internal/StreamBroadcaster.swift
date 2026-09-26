import Foundation

/// Multicast fan-out to many `AsyncStream` subscribers, backed by an actor.
///
/// Used by production and fake peripherals. `onTermination` cannot `await`, so unsubscribe
/// uses `Task { await remove(id) }` — a cancelled stream may receive one more event.
actor StreamBroadcaster<Element: Sendable> {
    private let replaysLatest: Bool
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var subscriberCount = 0
    private var subscriberCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var latest: Element?

    init(replaysLatest: Bool = false, initialLatest: Element? = nil) {
        self.replaysLatest = replaysLatest
        self.latest = initialLatest
    }

    func makeStream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id = UUID()
        continuations[id] = continuation
        subscriberCount += 1
        resumeSubscriberCountWaiters()

        if replaysLatest, let latest {
            continuation.yield(latest)
        }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task {
                await self.remove(id)
            }
        }

        return stream
    }

    func waitUntilSubscriberCount(_ target: Int) async {
        if subscriberCount == target {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            subscriberCountWaiters.append((target, continuation))
            resumeSubscriberCountWaiters()
        }
    }

    func yield(_ value: Element) {
        latest = value
        let active = Array(continuations.values)
        for continuation in active {
            continuation.yield(value)
        }
    }

    private func remove(_ id: UUID) {
        guard continuations.removeValue(forKey: id) != nil else {
            return
        }
        subscriberCount -= 1
        resumeSubscriberCountWaiters()
    }

    private func resumeSubscriberCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in subscriberCountWaiters {
            if subscriberCount == target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        subscriberCountWaiters = remaining
    }
}
