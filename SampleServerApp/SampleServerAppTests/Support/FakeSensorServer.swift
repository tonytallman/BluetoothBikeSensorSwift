import CSCServer
import Foundation
@testable import SampleServerApp

final class FakeMeasurementSubscriberCount: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Int>.Continuation?
    private var latest = 0
    private let sharedStream: AsyncStream<Int>

    init() {
        var capturedContinuation: AsyncStream<Int>.Continuation?
        sharedStream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
        continuation?.yield(0)
    }

    func stream() -> AsyncStream<Int> {
        sharedStream
    }

    func send(_ value: Int) {
        lock.lock()
        latest = value
        continuation?.yield(value)
        lock.unlock()
    }
}

actor FakeSensorServer: SensorServer {
    enum Script {
        case succeed
        case fail(ServerError)
        case suspendUntilCancelled
        case suspendUntilReleased(ignoresCancellation: Bool)
    }

    private let slot: FakeLiveServerSlot
    private let script: Script
    private let subscriberCounts: FakeMeasurementSubscriberCount
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private var startEnteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        slot: FakeLiveServerSlot,
        script: Script,
        subscriberCounts: FakeMeasurementSubscriberCount = FakeMeasurementSubscriberCount(),
    ) {
        self.slot = slot
        self.script = script
        self.subscriberCounts = subscriberCounts
    }

    var measurementSubscriberCount: AsyncStream<Int> {
        get async {
            subscriberCounts.stream()
        }
    }

    func setSubscriberCount(_ count: Int) {
        subscriberCounts.send(count)
    }

    func start() async throws {
        try slot.claim()
        startCount += 1
        resumeStartEnteredWaiters()

        switch script {
        case .succeed:
            return
        case let .fail(error):
            slot.release()
            throw error
        case .suspendUntilCancelled:
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                slot.release()
                throw CancellationError()
            }
            return
        case let .suspendUntilReleased(ignoresCancellation):
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
            if Task.isCancelled, !ignoresCancellation {
                slot.release()
                throw CancellationError()
            }
            return
        }
    }

    func stop() async {
        stopCount += 1
        subscriberCounts.send(0)
        slot.release()
    }

    func waitUntilStartEntered() async {
        if startCount > 0 { return }
        await withCheckedContinuation { continuation in
            startEnteredContinuations.append(continuation)
        }
    }

    func release() {
        let waiters = releaseContinuations
        releaseContinuations = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeStartEnteredWaiters() {
        let waiters = startEnteredContinuations
        startEnteredContinuations = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
