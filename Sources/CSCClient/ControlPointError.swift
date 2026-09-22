/// Errors thrown by SC Control Point procedures on a connected sensor.
public enum ControlPointError: Error, Sendable, Equatable {
    /// The requested sensor location is not in this sensor's supported list.
    case unsupportedLocation
    /// The sensor has no SC Control Point characteristic.
    ///
    /// Unreachable after a successful wheel or wheel-and-crank connect; wheel data requires
    /// SC Control Point at connect time per CSCS.
    case controlPointUnavailable
    /// Another control-point procedure is already in flight.
    case procedureInProgress
    /// The server indicated Op Code Not Supported.
    case opCodeNotSupported
    /// The server indicated Invalid Parameter.
    case invalidParameter
    /// The server indicated Operation Failed.
    case operationFailed
    /// The control-point CCCD is not configured for indications.
    case cccdImproperlyConfigured
    /// The procedure did not complete before the CSCS timeout elapsed.
    case timedOut
    /// The procedure failed for another reason.
    case failed(reason: String)
}
