package import CSCWire
import Foundation

package enum CSCControlPointClient {
    package static func supportedLocations(from response: CSCControlPointResponse) -> [SensorLocation]? {
        guard response.requestOpcode == CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
              response.value == CSCControlPointResponseValue.success.rawValue
        else {
            return nil
        }

        return response.parameter.map { SensorLocation.fromAssignedNumber($0) }
    }
}
