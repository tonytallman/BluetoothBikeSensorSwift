import Foundation

package enum CSCControlPointOpCode {
    package static let setCumulativeValue: UInt8 = 0x01
    package static let updateSensorLocation: UInt8 = 0x03
    package static let requestSupportedSensorLocations: UInt8 = 0x04
    package static let responseCode: UInt8 = 0x10
}

package enum CSCControlPointResponseValue {
    package static let success: UInt8 = 0x01
    package static let opCodeNotSupported: UInt8 = 0x02
    package static let invalidParameter: UInt8 = 0x03
    package static let operationFailed: UInt8 = 0x04
}

package enum CSCControlPointParser {
    package struct Response: Sendable, Equatable {
        package let requestOpcode: UInt8
        package let responseValue: UInt8
        package let parameter: Data
    }

    package static func parseResponse(_ data: Data) -> Response? {
        guard data.count >= 3, data[0] == CSCControlPointOpCode.responseCode else {
            return nil
        }

        return Response(
            requestOpcode: data[1],
            responseValue: data[2],
            parameter: Data(data.dropFirst(3)),
        )
    }

    package static func supportedLocations(from response: Response) -> [SensorLocation]? {
        guard response.requestOpcode == CSCControlPointOpCode.requestSupportedSensorLocations,
              response.responseValue == CSCControlPointResponseValue.success
        else {
            return nil
        }

        return response.parameter.map { SensorLocation.fromAssignedNumber($0) }
    }

    package static func encodeSetCumulativeValue(_ value: UInt32) -> Data {
        var data = Data([CSCControlPointOpCode.setCumulativeValue])
        data.append(contentsOf: encodeUInt32LE(value))
        return data
    }

    package static func encodeUpdateSensorLocation(_ location: SensorLocation) -> Data {
        Data([CSCControlPointOpCode.updateSensorLocation, location.assignedNumber])
    }

    package static func encodeRequestSupportedSensorLocations() -> Data {
        Data([CSCControlPointOpCode.requestSupportedSensorLocations])
    }

    private static func encodeUInt32LE(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24),
        ]
    }
}
