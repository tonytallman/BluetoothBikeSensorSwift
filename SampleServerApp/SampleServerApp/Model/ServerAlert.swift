import CSCServer
import Foundation

struct ServerAlert: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let offersSettings: Bool

    static func startFailure(
        _ error: Error,
        status: BluetoothStatus,
        authorization: BluetoothAuthorization,
    ) -> ServerAlert? {
        if error is CancellationError {
            return nil
        }
        if let serverError = error as? ServerError {
            switch serverError {
            case .notPoweredOn:
                switch authorization {
                case .denied, .restricted:
                    return ServerAlert(
                        message: "Bluetooth access is denied for this app. Allow it in Settings to start the server.",
                        offersSettings: true,
                    )
                default:
                    break
                }
                if status == .unsupported {
                    return ServerAlert(
                        message: "This device can't act as a Bluetooth LE peripheral. The iOS Simulator can't advertise; use a physical device.",
                        offersSettings: false,
                    )
                }
                return ServerAlert(
                    message: "Bluetooth is off or unavailable. Turn on Bluetooth and try again.",
                    offersSettings: false,
                )
            case .alreadyStarted:
                return ServerAlert(
                    message: "Another server in this app is still running or stopping. Try again in a moment.",
                    offersSettings: false,
                )
            case let .publishFailed(reason):
                return ServerAlert(
                    message: "Couldn't publish the CSC service: \(reason)",
                    offersSettings: false,
                )
            case let .advertisingFailed(reason):
                return ServerAlert(
                    message: "Couldn't start advertising: \(reason)",
                    offersSettings: false,
                )
            case .unsupportedConfiguration:
                return ServerAlert(
                    message: "This server configuration isn't supported.",
                    offersSettings: false,
                )
            }
        }
        return ServerAlert(
            message: String(describing: error),
            offersSettings: false,
        )
    }
}
