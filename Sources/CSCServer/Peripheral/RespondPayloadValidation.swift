import Foundation

package enum PeripheralRequestKind: Sendable {
    case read
    case write
}

package enum RespondPayloadValidation {
    package static func validate(
        requestKind: PeripheralRequestKind,
        result: ATTResult,
        value: Data?,
    ) throws {
        switch (requestKind, result) {
        case (.read, .success):
            guard value != nil else {
                throw BluetoothPeripheralError.missingReadValue
            }
        case (.read, .error), (.write, _):
            guard value == nil else {
                throw BluetoothPeripheralError.unexpectedResponseValue
            }
        }
    }
}
