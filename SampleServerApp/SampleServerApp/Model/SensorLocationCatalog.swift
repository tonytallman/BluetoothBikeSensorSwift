import CSCServer
import Foundation

enum SensorLocationCatalog {
    static let allKinds: [SensorLocationKind] = [
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

    static func displayName(for kind: SensorLocationKind) -> String {
        switch kind {
        case .other:
            "Other"
        case .topOfShoe:
            "Top of shoe"
        case .inShoe:
            "In shoe"
        case .hip:
            "Hip"
        case .frontWheel:
            "Front Wheel"
        case .leftCrank:
            "Left Crank"
        case .rightCrank:
            "Right Crank"
        case .leftPedal:
            "Left Pedal"
        case .rightPedal:
            "Right Pedal"
        case .frontHub:
            "Front Hub"
        case .rearDropout:
            "Rear Dropout"
        case .chainstay:
            "Chainstay"
        case .rearWheel:
            "Rear Wheel"
        case .rearHub:
            "Rear Hub"
        case .chest:
            "Chest"
        case .spider:
            "Spider"
        case .chainRing:
            "Chain Ring"
        }
    }

    static func supportedKinds(from selection: Set<SensorLocationKind>) -> [SensorLocationKind] {
        allKinds.filter { selection.contains($0) }
    }
}
