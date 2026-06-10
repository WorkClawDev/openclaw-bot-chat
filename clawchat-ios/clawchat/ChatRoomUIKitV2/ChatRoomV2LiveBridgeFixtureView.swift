import SwiftUI

struct ChatRoomV2LiveBridgeFixtureView: View {
    let context: ChatContext

    @State private var messages = ChatRoomV2LiveBridgeFixtureView.makeMessages(range: 41...100)
    @State private var didPrepend = false
    @State private var isNearBottom = true
    @State private var isUserScrolling = false

    private static let currentUserID = "fixture-user"

    var body: some View {
        ChatRoomUIKitV2MessageListView(
            context: context,
            messages: messages,
            currentUserID: Self.currentUserID,
            bottomAutoScrollThreshold: 96,
            historyPreloadDistance: 1_200,
            scrollCommand: .none,
            onLoadOlder: {},
            onNearBottomChange: { isNearBottom = $0 },
            onUserScrollChange: { isUserScrolling = $0 },
            onInitialPositioned: scheduleLiveBridgePrepend,
            onPreviewImage: { _ in },
            onSaveImage: { _ in },
            onTapList: {}
        )
        .accessibilityIdentifier("chatRoomV2.liveBridgeFixture")
    }

    private func scheduleLiveBridgePrepend() {
        guard !didPrepend else { return }
        didPrepend = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            messages = Self.makeMessages(range: 11...40) + messages
        }
    }

    private static func makeMessages(range: ClosedRange<Int>) -> [Message] {
        range.map { sequence in
            let isOutgoing = sequence.isMultiple(of: 3)
            let sender = MessagePeerPayload(
                type: isOutgoing ? "user" : "bot",
                id: isOutgoing ? currentUserID : "fixture-bot",
                name: isOutgoing ? "Fixture User" : "Fixture Bot",
                avatar: nil
            )
            let receiver = MessagePeerPayload(
                type: isOutgoing ? "bot" : "user",
                id: isOutgoing ? "fixture-bot" : currentUserID,
                name: nil,
                avatar: nil
            )
            let content = RealtimeContentPayload(
                type: "text",
                body: "#\(sequence) Live bridge message uses real SwiftUI updates before V2 renders deterministic geometry.",
                url: nil,
                name: nil,
                size: nil,
                meta: nil
            )
            let payload = RealtimeMessagePayload(
                id: "live-bridge-\(sequence)",
                topic: "ui-test-chat-v2",
                conversationId: "ui-test-chat-v2",
                timestamp: Int64(1_800_000_000 + sequence),
                from: sender,
                to: receiver,
                content: content,
                seq: Int64(sequence)
            )
            return Message(from: payload)
        }
    }
}
