import Foundation

struct ConversationLine: Identifiable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    enum State: String, Codable {
        case complete
        case live
    }

    let id: UUID
    let role: Role
    let text: String
    let state: State

    init(id: UUID = UUID(), role: Role, text: String, state: State) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
    }
}
