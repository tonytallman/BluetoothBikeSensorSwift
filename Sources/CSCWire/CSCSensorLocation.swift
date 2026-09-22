import Foundation

package struct CSCSensorLocation: Sendable, Hashable {
    package let assignedNumber: UInt8

    package init(assignedNumber: UInt8) {
        self.assignedNumber = assignedNumber
    }

    package static func decode(_ data: Data) -> CSCSensorLocation? {
        guard let first = data.first else {
            return nil
        }
        return CSCSensorLocation(assignedNumber: first)
    }

    package func encode() -> Data {
        Data([assignedNumber])
    }
}
