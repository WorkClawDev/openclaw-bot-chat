import SwiftUI
import UIKit

struct ChatRoomUIKitV2View: UIViewControllerRepresentable {
    let context: ChatContext
    var fixture: ChatRoomV2Fixture = .textPrependStress
    var compactMessageMode = false

    func makeUIViewController(context: Context) -> ChatRoomUIKitV2ViewController {
        let viewController = ChatRoomUIKitV2ViewController(context: self.context, fixture: fixture)
        viewController.applyCompactMessageMode(compactMessageMode)
        return viewController
    }

    func updateUIViewController(_ viewController: ChatRoomUIKitV2ViewController, context: Context) {
        viewController.applyCompactMessageMode(compactMessageMode)
    }
}

struct ChatRoomUIKitV2MessageListView: UIViewControllerRepresentable {
    let context: ChatContext
    let messages: [Message]
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
    var onOpenFile: ((FileBlockContentV2) -> Void)? = nil
    var compactMessageMode = false

    func makeUIViewController(context: Context) -> ChatRoomUIKitV2ViewController {
        let viewController = ChatRoomUIKitV2ViewController(context: self.context)
        viewController.applyCompactMessageMode(compactMessageMode)
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
        viewController.onOpenFile = onOpenFile
        viewController.applyScrollCommand(scrollCommand)
        return viewController
    }

    func updateUIViewController(_ viewController: ChatRoomUIKitV2ViewController, context: Context) {
        viewController.applyCompactMessageMode(compactMessageMode)
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
        viewController.onOpenFile = onOpenFile
        viewController.applyLiveMessages(messages, currentUserID: currentUserID)
        viewController.applyLiveHistoryState(isLoadingOlder: isLoadingOlder, hasMoreHistory: hasMoreHistory)
        viewController.applyScrollCommand(scrollCommand)
    }
}
