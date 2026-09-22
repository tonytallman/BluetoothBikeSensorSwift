/// GATT-assigned sensor location for the CSC server builder (assigned numbers 0...16).
public enum SensorLocationKind: Sendable, Equatable, Hashable {
    case other
    case topOfShoe
    case inShoe
    case hip
    case frontWheel
    case leftCrank
    case rightCrank
    case leftPedal
    case rightPedal
    case frontHub
    case rearDropout
    case chainstay
    case rearWheel
    case rearHub
    case chest
    case spider
    case chainRing

    package var assignedNumber: UInt8 {
        switch self {
        case .other: 0
        case .topOfShoe: 1
        case .inShoe: 2
        case .hip: 3
        case .frontWheel: 4
        case .leftCrank: 5
        case .rightCrank: 6
        case .leftPedal: 7
        case .rightPedal: 8
        case .frontHub: 9
        case .rearDropout: 10
        case .chainstay: 11
        case .rearWheel: 12
        case .rearHub: 13
        case .chest: 14
        case .spider: 15
        case .chainRing: 16
        }
    }
}
