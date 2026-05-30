import SwiftUI

// MARK: - MessagePreviewView

/// Standalone preview screen for `RenderedMessage` rendering.
///
/// Uses only mock data – does NOT touch `ChatRoomView`, `ChatRoomViewModel`,
/// UITableView, or any live chat state.
struct MessagePreviewView: View {

    private let items: [RenderedMessage] = MessagePreviewView.mockMessages()

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.messageID) { rendered in
                    RenderedMessageRow(rendered: rendered)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
            .listStyle(.plain)
            .navigationTitle("渲染预览")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Row

private struct RenderedMessageRow: View {
    let rendered: RenderedMessage

    private var alignment: HorizontalAlignment { rendered.isMe ? .trailing : .leading }

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Label(
                rendered.isMe ? "我" : "对方 (\(rendered.senderID))",
                systemImage: rendered.isMe ? "person.fill" : "person"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)

            ForEach(Array(rendered.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block, isMe: rendered.isMe)
            }
        }
        .frame(maxWidth: .infinity, alignment: rendered.isMe ? .trailing : .leading)
    }
}

// MARK: - Block Renderer

private struct BlockView: View {
    let block: MessageBlock
    let isMe: Bool

    var body: some View {
        Group {
            switch block {
            case .text(let b):
                Text(b.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? Color.blue.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

            case .markdown(let b):
                Text(b.raw)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? Color.blue.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

            case .code(let b):
                Text(b.source)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

            case .image(let b):
                ImagePlaceholderView(block: b)

            case .audio(let b):
                AudioPlaceholderView(block: b)

            case .loading:
                ProgressView()
                    .padding()

            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }
        }
    }
}

// MARK: - Placeholder Subviews

private struct ImagePlaceholderView: View {
    let block: ImageBlock

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.12))
                .frame(width: 160, height: 110)
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if let alt = block.altText {
                    Text(alt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct AudioPlaceholderView: View {
    let block: AudioBlock

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            if let dur = block.durationSeconds {
                Text(String(format: "%.0f\"", dur))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("语音消息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 220)
    }
}

// MARK: - Mock Data

extension MessagePreviewView {

    private static func mockMessages() -> [RenderedMessage] {
        [
            make(id: "1", isMe: true, blocks: [
                .text(TextBlock(content: "你好！有什么我可以帮你的吗？"))
            ]),
            make(id: "2", isMe: false, blocks: [
                .text(TextBlock(content: String(repeating: "在 Swift 中，actor 隔离可以防止数据竞争。每个 actor 都有独立的执行上下文，外部访问其可变状态必须通过 await。", count: 2)))
            ]),
            make(id: "3", isMe: true, blocks: [
                .image(ImageBlock(url: nil, altText: "截图.png"))
            ]),
            make(id: "4", isMe: false, blocks: [
                .audio(AudioBlock(url: nil, durationSeconds: 8))
            ]),
        ]
    }

    private static func make(id: String, isMe: Bool, blocks: [MessageBlock]) -> RenderedMessage {
        RenderedMessage(
            messageID: id,
            senderID: isMe ? "user-001" : "bot-001",
            isMe: isMe,
            blocks: blocks,
            renderSignature: id
        )
    }
}

// MARK: - Preview

#Preview {
    MessagePreviewView()
}
