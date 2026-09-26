/// Handles Set Cumulative Value (`0x01`) on SC Control Point for wheel revolution data.
///
/// ``Server/stop()`` cancels an in-flight call and waits for it to return; honor task cancellation.
///
/// The server cancels a call still running 30 seconds after the write was accepted. A call that
/// returns successfully after that has still been applied, and no indication is sent. The peer may
/// retry, so make your implementation safe to call again.
public protocol CumulativeWheelRevolutionsDelegate: Sendable {
    func setCumulativeWheelRevolutions(_ cumulativeRevolutions: UInt32) async throws
}
