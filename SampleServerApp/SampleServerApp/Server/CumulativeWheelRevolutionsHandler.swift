import CSCServer

struct CumulativeWheelRevolutionsHandler: CumulativeWheelRevolutionsDelegate {
    weak var sink: (any ControlPointEventSink)?

    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws {
        try Task.checkCancellation()
        let sink = sink
        await MainActor.run { [weak sink] in
            guard let sink else { return }
            sink.cumulativeWheelRevolutionsDidChange(to: cumulativeRevolutions)
        }
    }
}
