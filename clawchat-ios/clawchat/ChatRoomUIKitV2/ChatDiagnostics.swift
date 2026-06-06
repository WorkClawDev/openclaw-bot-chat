import Foundation
import os
import UIKit

enum ChatMutation: CustomStringConvertible {
    case initialLoad(count: Int)
    case prepend(count: Int)
    case append(messageID: String)
    case keyboardInset(CGFloat)

    var description: String {
        switch self {
        case .initialLoad(let count):
            return "initialLoad count=\(count)"
        case .prepend(let count):
            return "prepend count=\(count)"
        case .append(let messageID):
            return "append messageID=\(messageID)"
        case .keyboardInset(let inset):
            return "keyboardInset inset=\(inset)"
        }
    }
}

enum ChatDiagnostics {
    private static let logger = Logger(subsystem: "site.changer.clawchat", category: "ChatRoomUIKitV2")

    static func logMutation(_ mutation: ChatMutation) {
#if DEBUG
        logger.debug("mutation \(mutation.description, privacy: .public)")
#endif
    }

    static func logAnchorDrift(before: CGFloat, after: CGFloat) {
#if DEBUG
        let drift = abs(after - before)
        logger.debug("anchorDrift before=\(Double(before)) after=\(Double(after)) drift=\(Double(drift))")
        assert(drift <= 1.0, "ChatRoomUIKitV2 anchor drift exceeded 1 pt: \(drift)")
#endif
    }

    static func logRowHeightChange(messageID: String, old: CGFloat, new: CGFloat) {
#if DEBUG
        guard abs(old - new) > 0.5 else { return }
        logger.error("rowHeightChanged messageID=\(messageID, privacy: .public) old=\(Double(old)) new=\(Double(new))")
        assertionFailure("ChatRoomUIKitV2 row height changed after insertion for \(messageID)")
#endif
    }

    static func logUnexpectedReloadData() {
#if DEBUG
        logger.error("unexpected reloadData after initial load")
        assertionFailure("ChatRoomUIKitV2 must not call reloadData after initial load")
#endif
    }

    static func assertUniqueMessageIDs(_ messages: [RenderedMessage]) {
#if DEBUG
        let ids = messages.map(\.id)
        assert(Set(ids).count == ids.count, "ChatRoomUIKitV2 message IDs must be unique")
#endif
    }

    static func assertRenderedPageIsLaidOut(_ messages: [RenderedMessage]) {
#if DEBUG
        for message in messages {
            assert(message.layout.rowHeight > 0, "Rendered message must have non-zero row height")
            assert(!message.blocks.isEmpty, "Rendered message must contain at least one block")
        }
#endif
    }
}
