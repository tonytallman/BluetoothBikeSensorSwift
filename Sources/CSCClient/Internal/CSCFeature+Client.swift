import CSCWire

extension CSCFeature {
    var hasSpeed: Bool { contains(.wheelRevolutionData) }
    var hasCadence: Bool { contains(.crankRevolutionData) }
    var hasMultipleSensorLocations: Bool { contains(.multipleSensorLocations) }
}
