import Foundation

package enum ServerTestCondition: Sendable, Equatable {
    case measurementSubscribers(Set<UUID>)
    case controlPointSubscribers(Set<UUID>)
    case acceptedMeasurementCount(atLeast: Int)
    case outboundCount(atLeast: Int)
    case readyToUpdateWaiterParked
    case controlPointProcedureIdle
    case measurementSubscriberWaiterParked
    case bluetoothRecoveryIdle

    package var isSatisfiedByClose: Bool {
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
