import SwiftUI
import UIKit

enum ChatRoomV2BridgeUpdateOrderingV2 {
    static func apply(
        shouldApplyMessages: Bool,
        applyMessages: () -> Void,
        applyHistoryState: () -> Void,
        applyScrollCommand: () -> Void
    ) {
        if shouldApplyMessages {
            applyMessages()
        }
        applyHistoryState()
        applyScrollCommand()
    }
}

struct ChatRoomUIKitV2View: UIViewControllerRepresentable {
    let context: ChatContext
    var fixture: ChatRoomV2Fixture = .textPrependStress

    func makeUIViewController(context: Context) -> ChatRoomUIKitV2ViewController {
        ChatRoomUIKitV2ViewController(context: self.context, fixture: fixture)
    }

    func updateUIViewController(_ viewController: ChatRoomUIKitV2ViewController, context: Context) {
    }
}

struct ChatRoomUIKitV2MessageListView: UIViewControllerRepresentable {
    let context: ChatContext
    let messages: [Message]
    var messageSnapshotRevision: UInt64? = nil
    var changedMessageIDs: Set<String>? = nil
    let currentUserID: String?
    let bottomAutoScrollThreshold: CGFloat
    let historyPreloadDistance: CGFloat
    let isLoadingOlder: Bool
    let hasMoreHistory: Bool
    let scrollCommand: ChatListScrollCommand
    let onLoadOlder: () -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrollChange: (Bool) -> Void
    let onInitialPositioned: () -> Void
    let onPreviewImage: (Message) -> Void
    let onSaveImage: (Message) -> Void
    let onOpenDocument: (UUID) -> Void
    let onContinueDocument: (DocumentLinkPreview) -> Void
    let onTapList: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> ChatRoomUIKitV2ViewController {
        let viewController = ChatRoomUIKitV2ViewController(context: self.context)
        viewController.bottomAutoScrollThreshold = bottomAutoScrollThreshold
        viewController.historyPreloadDistance = historyPreloadDistance
        viewController.onLoadOlder = onLoadOlder
        viewController.onNearBottomChange = onNearBottomChange
        viewController.onUserScrollChange = onUserScrollChange
        viewController.onInitialPositioned = onInitialPositioned
        viewController.onPreviewImage = onPreviewImage
        viewController.onSaveImage = onSaveImage
        viewController.onOpenDocument = onOpenDocument
        viewController.onContinueDocument = onContinueDocument
        viewController.onTapList = onTapList
        viewController.applyScrollCommand(scrollCommand)
        return viewController
    }

    func updateUIViewController(_ viewController: ChatRoomUIKitV2ViewController, context: Context) {
        viewController.bottomAutoScrollThreshold = bottomAutoScrollThreshold
        viewController.historyPreloadDistance = historyPreloadDistance
        viewController.onLoadOlder = onLoadOlder
        viewController.onNearBottomChange = onNearBottomChange
        viewController.onUserScrollChange = onUserScrollChange
        viewController.onInitialPositioned = onInitialPositioned
        viewController.onPreviewImage = onPreviewImage
        viewController.onSaveImage = onSaveImage
        viewController.onOpenDocument = onOpenDocument
        viewController.onContinueDocument = onContinueDocument
        viewController.onTapList = onTapList
        let signature = ChatRoomV2BridgeSnapshotSignature(
            messages: messages,
            currentUserID: currentUserID,
            revision: messageSnapshotRevision
        )
        ChatRoomV2BridgeUpdateOrderingV2.apply(
            shouldApplyMessages: context.coordinator.shouldApplyMessages(signature)
        ) {
            viewController.applyLiveMessages(
                messages,
                currentUserID: currentUserID,
                snapshotRevision: messageSnapshotRevision,
                changedMessageIDs: changedMessageIDs
            )
        } applyHistoryState: {
            viewController.applyLiveHistoryState(isLoadingOlder: isLoadingOlder, hasMoreHistory: hasMoreHistory)
        } applyScrollCommand: {
            viewController.applyScrollCommand(scrollCommand)
        }
    }

    final class Coordinator {
        private var lastMessageSignature: ChatRoomV2BridgeSnapshotSignature?

        func shouldApplyMessages(_ signature: ChatRoomV2BridgeSnapshotSignature) -> Bool {
            guard signature != lastMessageSignature else { return false }
            lastMessageSignature = signature
            return true
        }
    }
}

struct ChatRoomV2BridgeSnapshotSignature: Equatable {
    let revision: UInt64?
    let messageCount: Int
    let normalizedCurrentUserID: String
    let contentSignatures: [ChatRoomV2MessageContentSignature]?

    init(messages: [Message], currentUserID: String?, revision: UInt64?) {
        self.revision = revision
        self.messageCount = messages.count
        self.normalizedCurrentUserID = Self.normalizeIdentifier(currentUserID)
        if revision == nil {
            self.contentSignatures = messages.map { ChatRoomV2MessageContentSignature($0) }
        } else {
            self.contentSignatures = nil
        }
    }

    private static func normalizeIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

struct ChatRoomV2MessageContentSignature: Hashable {
    let id: String
    let conversationID: String
    let topic: String
    let senderID: String
    let senderType: String
    let fromType: String
    let fromID: String
    let fromName: String?
    let fromAvatar: String?
    let toType: String
    let toID: String
    let toName: String?
    let toAvatar: String?
    let contentType: String
    let contentBody: String?
    let contentURL: String?
    let contentName: String?
    let contentSize: Int?
    let contentMetadata: String?
    let sequence: Int?
    let timestamp: Int64?
    let createdAt: Date?
    let isPending: Bool
    let isFailed: Bool

    init(_ message: Message) {
        id = message.id
        conversationID = message.conversationId
        topic = message.topic
        senderID = message.senderId
        senderType = message.senderType
        fromType = message.from.type
        fromID = message.from.id
        fromName = message.from.name
        fromAvatar = message.from.avatar
        toType = message.to.type
        toID = message.to.id
        toName = message.to.name
        toAvatar = message.to.avatar
        contentType = message.content.type
        contentBody = message.content.body
        contentURL = message.content.url
        contentName = message.content.name
        contentSize = message.content.size
        contentMetadata = Self.canonicalMetadata(message.content.meta)
        sequence = message.seq
        timestamp = message.timestamp
        createdAt = message.createdAt
        isPending = message.pending
        isFailed = message.failed
    }

    private static func canonicalMetadata(_ metadata: [String: AnyCodable]?) -> String? {
        guard let metadata else { return nil }
        return canonicalDictionary(metadata)
    }

    private static func canonicalDictionary(_ dictionary: [String: AnyCodable]) -> String {
        dictionary.keys.sorted().map { key in
            "\(encoded(key))=\(canonicalValue(dictionary[key]!.value))"
        }.joined(separator: "|")
    }

    private static func canonicalValue(_ value: Any) -> String {
        if value is NSNull {
            return "n"
        }
        if let value = value as? String {
            return "s\(encoded(value))"
        }
        if let value = value as? Bool {
            return value ? "b1" : "b0"
        }
        if let value = value as? Int {
            return "i\(value)"
        }
        if let value = value as? Int64 {
            return "l\(value)"
        }
        if let value = value as? Double {
            return "d\(value.bitPattern)"
        }
        if let value = value as? [String: AnyCodable] {
            return "o{\(canonicalDictionary(value))}"
        }
        if let value = value as? [AnyCodable] {
            return "a[\(value.map { canonicalValue($0.value) }.joined(separator: ","))]"
        }
        return "x\(encoded(String(reflecting: value)))"
    }

    private static func encoded(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
