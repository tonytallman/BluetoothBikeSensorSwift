import Foundation

struct ControlPointLogEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String

    init(date: Date = Date(), text: String) {
        self.id = UUID()
        self.date = date
        self.text = text
    }
}
