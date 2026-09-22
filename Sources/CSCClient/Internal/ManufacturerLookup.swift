import Foundation

enum ManufacturerLookup {
    /// Bluetooth SIG company identifiers (16-bit), little-endian in advertisement data.
    private static let companyNames: [UInt16: String] = [
        0x006D: "Garmin",
        0x0077: "Wahoo Fitness",
        0x0099: "Stages Cycling",
        0x00D1: "Quarq",
        0x0137: "Magene",
        0x0154: "Cycling Power Meter",
        0x0157: "SRAM",
    ]

    static func manufacturerName(from manufacturerData: Data?) -> String? {
        guard let manufacturerData, manufacturerData.count >= 2 else {
            return nil
        }

        let companyID = manufacturerData.withUnsafeBytes { buffer in
            buffer.load(as: UInt16.self)
        }

        return companyNames[companyID]
    }
}
