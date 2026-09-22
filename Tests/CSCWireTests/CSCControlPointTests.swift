import CSCWire
import Foundation
import Testing

@Suite struct CSCControlPointTests {
    @Test func encodesAndDecodesSetCumulativeValue() {
        let request = CSCControlPointRequest.setCumulativeValue(1_000)
        let decoded = CSCControlPointRequest.decode(request.encode())
        #expect(decoded == request)
    }

    @Test func encodesAndDecodesUpdateSensorLocation() {
        let request = CSCControlPointRequest.updateSensorLocation(0x05)
        let decoded = CSCControlPointRequest.decode(request.encode())
        #expect(decoded == request)
    }

    @Test func encodesAndDecodesRequestSupportedSensorLocations() {
        let request = CSCControlPointRequest.requestSupportedSensorLocations
        let decoded = CSCControlPointRequest.decode(request.encode())
        #expect(decoded == request)
    }

    @Test func encodesAndDecodesStartSensorCalibration() {
        let request = CSCControlPointRequest.startSensorCalibration
        #expect(request.encode() == Data([0x02]))
        #expect(CSCControlPointRequest.decode(Data([0x02])) == .startSensorCalibration)
    }

    @Test func startSensorCalibrationRejectsExtraBytes() {
        #expect(
            CSCControlPointRequest.decode(Data([0x02, 0xFF]))
                == .invalidParameter(opcode: 0x02, parameter: Data([0xFF])),
        )
    }

    @Test func decodesUnknownOpcode() {
        let decoded = CSCControlPointRequest.decode(Data([0x99, 0x01, 0x02]))
        #expect(decoded == .unknown(opcode: 0x99, parameter: Data([0x01, 0x02])))
    }

    @Test func responseCodeOpcodeIsUnknownRequest() {
        let decoded = CSCControlPointRequest.decode(Data([0x10, 0x01, 0x02]))
        #expect(decoded == .unknown(opcode: 0x10, parameter: Data([0x01, 0x02])))
    }

    @Test func rejectsEmptyRequest() {
        #expect(CSCControlPointRequest.decode(Data()) == nil)
    }

    @Test func rejectsShortSetCumulativeValue() {
        #expect(
            CSCControlPointRequest.decode(Data([0x01, 0x00, 0x00, 0x00]))
                == .invalidParameter(opcode: 0x01, parameter: Data([0x00, 0x00, 0x00])),
        )
    }

    @Test func rejectsShortUpdateSensorLocation() {
        #expect(
            CSCControlPointRequest.decode(Data([0x03]))
                == .invalidParameter(opcode: 0x03, parameter: Data()),
        )
    }

    @Test func rejectsExtraBytesOnUpdateSensorLocation() {
        #expect(
            CSCControlPointRequest.decode(Data([0x03, 0x05, 0xFF]))
                == .invalidParameter(opcode: 0x03, parameter: Data([0x05, 0xFF])),
        )
    }

    @Test func rejectsExtraBytesOnRequestSupportedSensorLocations() {
        #expect(
            CSCControlPointRequest.decode(Data([0x04, 0xFF]))
                == .invalidParameter(opcode: 0x04, parameter: Data([0xFF])),
        )
    }

    @Test func rejectsExtraBytesOnKnownRequest() {
        let decoded = CSCControlPointRequest.decode(Data([0x01, 0x01, 0x00, 0x00, 0x00, 0xFF]))
        #expect(
            decoded == .invalidParameter(
                opcode: 0x01,
                parameter: Data([0x01, 0x00, 0x00, 0x00, 0xFF]),
            ),
        )
    }

    @Test func encodesAndDecodesSuccessResponse() {
        let response = CSCControlPointResponse(
            requestOpcode: CSCControlPointOpCode.requestSupportedSensorLocations.rawValue,
            value: CSCControlPointResponseValue.success.rawValue,
            parameter: Data([0x05, 0x06]),
        )
        let decoded = CSCControlPointResponse.decode(response.encode())
        #expect(decoded == response)
    }

    @Test func rejectsResponseWithoutResponseCodeOpcode() {
        #expect(CSCControlPointResponse.decode(Data([0x04, 0x01, 0x01])) == nil)
    }

    @Test func decodesUnknownResponseValue() {
        let response = CSCControlPointResponse(
            requestOpcode: 0x04,
            value: 0x99,
            parameter: Data(),
        )
        let decoded = CSCControlPointResponse.decode(response.encode())
        #expect(decoded == response)
    }
}
