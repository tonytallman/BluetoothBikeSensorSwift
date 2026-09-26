import Foundation

package struct Advertisement: Sendable, Equatable {
    package let localName: String?
    package let serviceUUIDs: [UUID]

    package init(localName: String?, serviceUUIDs: [UUID]) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
    }
}
