import CSCServer
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AnyAsyncSequenceTests {
    @Test func iteratorsAreIndependent() async throws {
        let sequence = AnyAsyncSequence(CountingSequence(limit: 3))
        let first = sequence.makeAsyncIterator()
        let second = sequence.makeAsyncIterator()

        #expect(try await first.next() == 1)
        #expect(try await first.next() == 2)
        #expect(try await second.next() == 1)
        #expect(try await first.next() == 3)
        #expect(try await second.next() == 2)
        #expect(try await first.next() == nil)
        #expect(try await second.next() == 3)
        #expect(try await second.next() == nil)
    }

    @Test func errorsPropagate() async throws {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let sequence = AnyAsyncSequence(stream)
        let iterator = sequence.makeAsyncIterator()

        continuation.yield(7)
        continuation.finish(throwing: SourceError.failed)

        #expect(try await iterator.next() == 7)
        await #expect(throws: SourceError.failed) {
            try await iterator.next()
        }
    }
}

private enum SourceError: Error {
    case failed
}

/// Multi-pass sequence whose iterator is a non-`Sendable` class.
private struct CountingSequence: AsyncSequence, Sendable {
    typealias Element = Int

    let limit: Int

    final class Iterator: AsyncIteratorProtocol {
        private let limit: Int
        private var current = 0

        init(limit: Int) {
            self.limit = limit
        }

        func next() async throws -> Int? {
            guard current < limit else {
                return nil
            }
            current += 1
            return current
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(limit: limit)
    }
}
