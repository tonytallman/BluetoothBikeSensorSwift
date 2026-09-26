package struct AnyAsyncSequence<Element: Sendable>: Sendable {
    private let makeIterator: @Sendable () -> Iterator

    package init<Base: AsyncSequence & Sendable>(
        _ base: Base,
    ) where Base.Element == Element {
        makeIterator = {
            Iterator(box: IteratorBox(base: base.makeAsyncIterator()))
        }
    }

    package func makeAsyncIterator() -> Iterator {
        makeIterator()
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let nextValue: () async throws -> Element?

        fileprivate init<Base: AsyncIteratorProtocol>(
            box: IteratorBox<Base>,
        ) where Base.Element == Element {
            nextValue = {
                try await box.next()
            }
        }

        package func next() async throws -> Element? {
            try await nextValue()
        }
    }
}

/// Holds a base iterator that need not be `Sendable`, such as `AsyncStream.Iterator`.
///
/// Each `makeAsyncIterator()` creates its own box. `ServerSession` iterates each box from exactly
/// one task (`startRevolutionLoop`), so `next()` calls never overlap.
/// The iterator must not cross into a second task.
private final class IteratorBox<Base: AsyncIteratorProtocol>: @unchecked Sendable where Base.Element: Sendable {
    private var base: Base

    init(base: Base) {
        self.base = base
    }

    func next() async throws -> Base.Element? {
        try await base.next()
    }
}
