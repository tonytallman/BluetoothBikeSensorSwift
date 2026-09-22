package struct AnyAsyncSequence<Element: Sendable>: Sendable {
    private let makeIterator: @Sendable () -> Iterator

    package init<Base: AsyncSequence & Sendable>(
        _ base: Base,
    ) where Base.Element == Element, Base.AsyncIterator: Sendable {
        makeIterator = {
            Iterator(base: base)
        }
    }

    package func makeAsyncIterator() -> Iterator {
        makeIterator()
    }

    package struct Iterator: AsyncIteratorProtocol {
        private let nextValue: () async throws -> Element?

        fileprivate init<Base: AsyncSequence & Sendable>(
            base: Base,
        ) where Base.Element == Element, Base.AsyncIterator: Sendable {
            let actor = IteratorActor(iterator: base.makeAsyncIterator())
            nextValue = {
                try await actor.next()
            }
        }

        package func next() async throws -> Element? {
            try await nextValue()
        }
    }
}

private actor IteratorActor<I: AsyncIteratorProtocol & Sendable> {
    private var iterator: I

    init(iterator: I) {
        self.iterator = iterator
    }

    func next() async throws -> I.Element? {
        var local = iterator
        let value = try await local.next()
        iterator = local
        return value
    }
}
