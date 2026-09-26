import Foundation

package enum ServerTestCondition: Sendable {
    case measurementSubscribers(Set<UUID>)
    case controlPointSubscribers(Set<UUID>)
    case acceptedMeasurementCount(atLeast: Int)
    case outboundCount(atLeast: Int)
    case readyToUpdateWaiterParked
    case controlPointProcedureIdle
    case measurementSubscriberWaiterParked
    case bluetoothRecoveryIdle

    var isSatisfiedByClose: Bool {
        switch self {
        case .measurementSubscribers,
             .controlPointSubscribers,
             .acceptedMeasurementCount,
             .outboundCount,
             .readyToUpdateWaiterParked:
            return true
        case .controlPointProcedureIdle,
             .measurementSubscriberWaiterParked,
             .bluetoothRecoveryIdle:
            return false
        }
    }
}
