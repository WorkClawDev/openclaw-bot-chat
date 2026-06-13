import SwiftUI

struct ChatRoomV2StatusStabilityFixtureView: View {
    let context: ChatContext

    @State private var messages = [
        Self.message(id: "remote-100", sequence: 100, body: "Remote message before local delivery state."),
        Self.message(id: "failed-local", sequence: nil, body: "Failed local message should keep its visual slot.", failed: true),
        Self.message(id: "pending-local", sequence: nil, body: "Pending local message should keep its visual slot.", pending: true)
    ]
    @State private var didAppendRemote = false

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
            onInitialPositioned: appendRemoteAfterLocalStatusRows,
            onPreviewImage: { _ in },
            onSaveImage: { _ in },
            onOpenDocument: { _ in },
            onContinueDocument: { _ in },
            onTapList: {}
        )
        .overlay(alignment: .topLeading) {
            Text(didAppendRemote ? "appended" : "initial")
                .font(.caption2)
                .foregroundStyle(.clear)
                .accessibilityIdentifier("chatRoomV2.statusStability.phase")
        }
        .accessibilityIdentifier("chatRoomV2.statusStabilityFixture")
    }

    private func appendRemoteAfterLocalStatusRows() {
        guard !didAppendRemote else { return }
        didAppendRemote = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            messages.append(Self.message(id: "remote-101", sequence: 101, body: "Remote refresh should not push failed local rows below it."))
        }
    }

    private static func message(
        id: String,
        sequence: Int?,
        body: String,
        pending: Bool = false,
        failed: Bool = false
    ) -> Message {
        let isOutgoing = pending || failed
        var message = Message(from: RealtimeMessagePayload(
            id: id,
            topic: "ui-test-chat-v2",
            conversationId: "ui-test-chat-v2",
            timestamp: Int64(1_800_000_000 + (sequence ?? 100)),
            from: MessagePeerPayload(
                type: isOutgoing ? "user" : "bot",
                id: isOutgoing ? "fixture-user" : "fixture-bot",
                name: isOutgoing ? "Fixture User" : "Fixture Bot",
                avatar: nil
            ),
            to: MessagePeerPayload(
                type: isOutgoing ? "bot" : "user",
                id: isOutgoing ? "fixture-bot" : "fixture-user",
                name: nil,
                avatar: nil
            ),
            content: RealtimeContentPayload(type: "text", body: body, url: nil, name: nil, size: nil, meta: nil),
            seq: sequence.map(Int64.init)
        ), pending: pending, failed: failed)
        message.failed = failed
        return message
    }
}
