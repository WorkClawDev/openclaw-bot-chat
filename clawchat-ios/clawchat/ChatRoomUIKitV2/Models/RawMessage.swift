import Foundation

enum MessageStatus: Equatable {
    case sending
    case streaming
    case complete
    case failed
}

enum RawMessageContent: Equatable {
    case text(String)
}

struct RawMessage: Identifiable, Equatable {
    let id: String
    let senderID: String
    let conversationID: String
    let content: RawMessageContent
    let createdAt: Date
    let status: MessageStatus
    let contentVersion: String
}
