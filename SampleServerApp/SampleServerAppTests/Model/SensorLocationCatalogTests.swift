import CSCServer
import Testing
@testable import SampleServerApp

@Suite(.serialized) struct SensorLocationCatalogTests {
    @Test func seventeenKindsInOrder() {
        #expect(SensorLocationCatalog.allKinds.count == 17)
        #expect(Set(SensorLocationCatalog.allKinds).count == 17)
        #expect(SensorLocationCatalog.allKinds.first == .other)
        #expect(SensorLocationCatalog.allKinds.last == .chainRing)
    }

    @Test func displayNamesMatchClient() {
        let expected: [(SensorLocationKind, String)] = [
            (.other, "Other"),
            (.topOfShoe, "Top of shoe"),
            (.inShoe, "In shoe"),
            (.hip, "Hip"),
            (.frontWheel, "Front Wheel"),
            (.leftCrank, "Left Crank"),
            (.rightCrank, "Right Crank"),
            (.leftPedal, "Left Pedal"),
            (.rightPedal, "Right Pedal"),
            (.frontHub, "Front Hub"),
            (.rearDropout, "Rear Dropout"),
            (.chainstay, "Chainstay"),
            (.rearWheel, "Rear Wheel"),
            (.rearHub, "Rear Hub"),
            (.chest, "Chest"),
            (.spider, "Spider"),
            (.chainRing, "Chain Ring"),
        ]
        for (kind, name) in expected {
            #expect(SensorLocationCatalog.displayName(for: kind) == name)
        }
    }
}
