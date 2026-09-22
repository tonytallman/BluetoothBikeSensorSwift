import Foundation

package enum CSCControlPointOpCode: UInt8, Sendable {
    case setCumulativeValue = 0x01
    case startSensorCalibration = 0x02
    case updateSensorLocation = 0x03
    case requestSupportedSensorLocations = 0x04
    case responseCode = 0x10
}

package enum CSCControlPointRequest: Sendable, Equatable {
    case setCumulativeValue(UInt32)
    case startSensorCalibration
    case updateSensorLocation(UInt8)
    case requestSupportedSensorLocations
    case unknown(opcode: UInt8, parameter: Data)

    package static func decode(_ data: Data) -> CSCControlPointRequest? {
        guard let opcode = data.first else {
            return nil
        }

        let parameter = Data(data.dropFirst())

        switch opcode {
        case CSCControlPointOpCode.setCumulativeValue.rawValue:
            guard parameter.count >= 4 else {
                return nil
            }
            let value = LittleEndian.readUInt32(parameter, 0)
            return .setCumulativeValue(value)
        case CSCControlPointOpCode.startSensorCalibration.rawValue:
            return .startSensorCalibration
        case CSCControlPointOpCode.updateSensorLocation.rawValue:
            guard let location = parameter.first else {
                return nil
            }
            return .updateSensorLocation(location)
        case CSCControlPointOpCode.requestSupportedSensorLocations.rawValue:
            return .requestSupportedSensorLocations
        case CSCControlPointOpCode.responseCode.rawValue:
            return .unknown(opcode: opcode, parameter: parameter)
        default:
            return .unknown(opcode: opcode, parameter: parameter)
        }
    }

    package func encode() -> Data {
        switch self {
        case let .setCumulativeValue(value):
            var data = Data([CSCControlPointOpCode.setCumulativeValue.rawValue])
            data.append(contentsOf: LittleEndian.writeUInt32(value))
            return data
        case .startSensorCalibration:
            return Data([CSCControlPointOpCode.startSensorCalibration.rawValue])
        case let .updateSensorLocation(assignedNumber):
            return Data([
                CSCControlPointOpCode.updateSensorLocation.rawValue,
                assignedNumber,
            ])
        case .requestSupportedSensorLocations:
            return Data([CSCControlPointOpCode.requestSupportedSensorLocations.rawValue])
        case let .unknown(opcode, parameter):
            var data = Data([opcode])
            data.append(parameter)
            return data
        }
    }
}

package enum CSCControlPointResponseValue: UInt8, Sendable {
    case success = 0x01
    case opCodeNotSupported = 0x02
    case invalidParameter = 0x03
    case operationFailed = 0x04
}

package struct CSCControlPointResponse: Sendable, Equatable {
    package let requestOpcode: UInt8
    package let value: UInt8
    package let parameter: Data

    package init(
        requestOpcode: UInt8,
        value: UInt8,
        parameter: Data,
    ) {
        self.requestOpcode = requestOpcode
        self.value = value
        self.parameter = parameter
    }

    package static func decode(_ data: Data) -> CSCControlPointResponse? {
        guard data.count >= 3, data[0] == CSCControlPointOpCode.responseCode.rawValue else {
            return nil
        }

        return CSCControlPointResponse(
            requestOpcode: data[1],
            value: data[2],
            parameter: Data(data.dropFirst(3)),
        )
    }

    package func encode() -> Data {
        var data = Data([
            CSCControlPointOpCode.responseCode.rawValue,
            requestOpcode,
            value,
        ])
        data.append(parameter)
        return data
    }
}
