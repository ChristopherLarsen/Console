import Foundation
import SwiftData

@Model
final class WakeWord: Identifiable {
    @Attribute(.unique) var id: UUID
    var word: String
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        word: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.word = word
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}
