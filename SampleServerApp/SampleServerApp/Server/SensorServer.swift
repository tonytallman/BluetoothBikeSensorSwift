protocol SensorServer: AnyObject, Sendable {
    func start() async throws
    func stop() async
    var measurementSubscriberCount: AsyncStream<Int> { get async }
}
