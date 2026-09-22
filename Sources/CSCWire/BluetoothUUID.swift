import Foundation

enum BluetoothUUID {
    static func standard(_ shortUUID: String) -> UUID {
        UUID(uuidString: "0000\(shortUUID)-0000-1000-8000-00805F9B34FB")!
    }
}
