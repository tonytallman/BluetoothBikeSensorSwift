import CSCServer
import Testing

struct SensorLocationKindTests {
    @Test func assignedNumbersMatchGATT() {
        #expect(SensorLocationKind.other.assignedNumber == 0)
        #expect(SensorLocationKind.topOfShoe.assignedNumber == 1)
        #expect(SensorLocationKind.inShoe.assignedNumber == 2)
        #expect(SensorLocationKind.hip.assignedNumber == 3)
        #expect(SensorLocationKind.frontWheel.assignedNumber == 4)
        #expect(SensorLocationKind.leftCrank.assignedNumber == 5)
        #expect(SensorLocationKind.rightCrank.assignedNumber == 6)
        #expect(SensorLocationKind.leftPedal.assignedNumber == 7)
        #expect(SensorLocationKind.rightPedal.assignedNumber == 8)
        #expect(SensorLocationKind.frontHub.assignedNumber == 9)
        #expect(SensorLocationKind.rearDropout.assignedNumber == 10)
        #expect(SensorLocationKind.chainstay.assignedNumber == 11)
        #expect(SensorLocationKind.rearWheel.assignedNumber == 12)
        #expect(SensorLocationKind.rearHub.assignedNumber == 13)
        #expect(SensorLocationKind.chest.assignedNumber == 14)
        #expect(SensorLocationKind.spider.assignedNumber == 15)
        #expect(SensorLocationKind.chainRing.assignedNumber == 16)
    }

    @Test func allCasesAreUnique() {
        let cases: [SensorLocationKind] = [
            .other,
            .topOfShoe,
            .inShoe,
            .hip,
            .frontWheel,
            .leftCrank,
            .rightCrank,
            .leftPedal,
            .rightPedal,
            .frontHub,
            .rearDropout,
            .chainstay,
            .rearWheel,
            .rearHub,
            .chest,
            .spider,
            .chainRing,
        ]
        #expect(Set(cases).count == 17)
    }
}
