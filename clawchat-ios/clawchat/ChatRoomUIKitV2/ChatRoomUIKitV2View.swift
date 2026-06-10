import SwiftUI
import UIKit

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
    let currentUserID: String?
    let bottomAutoScrollThreshold: CGFloat
    let historyPreloadDistance: CGFloat
    let scrollCommand: ChatListScrollCommand
    let onLoadOlder: () -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrollChange: (Bool) -> Void
    let onInitialPositioned: () -> Void
    let onPreviewImage: (Message) -> Void
    let onSaveImage: (Message) -> Void
    let onTapList: () -> Void

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
        viewController.onTapList = onTapList
        viewController.applyLiveMessages(messages, currentUserID: currentUserID)
        viewController.applyScrollCommand(scrollCommand)
    }
}
