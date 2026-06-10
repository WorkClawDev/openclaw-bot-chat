import SwiftUI
import UIKit

struct ChatRoomV2ImagePreviewFixtureView: View {
    let context: ChatContext

    @State private var previewMessage: Message?

    private let messages = [Self.imageMessage]

    init(context: ChatContext) {
        self.context = context
        Self.cacheFixtureImageIfNeeded()
    }

    var body: some View {
        ChatRoomUIKitV2MessageListView(
            context: context,
            messages: messages,
            currentUserID: "fixture-user",
            bottomAutoScrollThreshold: 96,
            historyPreloadDistance: 1_200,
            scrollCommand: .none,
            onLoadOlder: {},
            onNearBottomChange: { _ in },
            onUserScrollChange: { _ in },
            onInitialPositioned: {},
            onPreviewImage: { previewMessage = $0 },
            onSaveImage: { _ in },
            onTapList: {}
        )
        .accessibilityIdentifier("chatRoomV2.imagePreviewFixture")
        .fullScreenCover(item: $previewMessage) { message in
            ChatImagePreviewScreen(message: message)
        }
    }

    private static let imageMessage: Message = {
        Message(
            from: RealtimeMessagePayload(
                id: "v2-live-image-message",
                topic: "ui-test-chat-v2",
                conversationId: "ui-test-chat-v2",
                timestamp: 1_800_000_120,
                from: MessagePeerPayload(type: "bot", id: "fixture-bot", name: "Fixture Bot", avatar: nil),
                to: MessagePeerPayload(type: "user", id: "fixture-user", name: "Fixture User", avatar: nil),
                content: RealtimeContentPayload(
                    type: "image",
                    body: "Fixture image preview",
                    url: "fixture://chat-room-v2/app-logo.jpg",
                    name: "app-logo.jpg",
                    size: nil,
                    meta: [
                        "width": AnyCodable(1024),
                        "height": AnyCodable(1024)
                    ]
                ),
                seq: 120
            )
        )
    }()

    private static func cacheFixtureImageIfNeeded() {
        guard let image = UIImage(named: "AppLogo"),
              let data = image.jpegData(compressionQuality: 0.92)
        else {
            return
        }
        LocalImageStore.shared.cacheImageData(
            data,
            for: imageMessage.content,
            fallbackIdentifier: imageMessage.id
        )
    }
}
