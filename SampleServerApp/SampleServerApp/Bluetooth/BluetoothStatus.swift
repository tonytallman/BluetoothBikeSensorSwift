enum BluetoothStatus: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

enum BluetoothAuthorization: Equatable {
    case notDetermined
    case restricted
    case denied
    case allowed

    var displayTitle: String {
        switch self {
        case .notDetermined:
            "Not determined"
        case .restricted:
            "Restricted"
        case .denied:
            "Denied"
        case .allowed:
            "Allowed"
        }
    }
}

extension BluetoothStatus {
    var displayTitle: String {
        switch self {
        case .unknown:
            "Unknown"
        case .resetting:
            "Resetting"
        case .unsupported:
            "Unsupported"
        case .unauthorized:
            "Unauthorized"
        case .poweredOff:
            "Powered off"
        case .poweredOn:
            "Powered on"
        }
    }
}
