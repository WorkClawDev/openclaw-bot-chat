import SwiftUI
import UIKit
import MarkdownUI

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

// MARK: - Block Dispatcher

private struct BlockView: View {
    let block: MessageBlock
    let isMe: Bool

    var body: some View {
        Group {
            switch block {
            case .text(let b):
                Text(b.content)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMe ? Color.blue.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

            case .markdown(let b):
                MarkdownBlockView(block: b, isMe: isMe)

            case .code(let b):
                // Reuse the shared RenderedCodeBlockView (no highlighting task)
                RenderedCodeBlockView(block: b, isMe: isMe)
                    .background(Color(UIColor.secondarySystemGroupedBackground))

            case .image(let b):
                // Use RenderedImageBlockView with pre-computed displaySize
                RenderedImageBlockView(block: b, isMe: isMe, onPreviewImage: nil)

            case .audio(let b):
                PreviewAudioPlaceholderView(block: b)

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

// MARK: - Markdown Block View (preview theme)

/// Renders a `MarkdownBlock` using MarkdownUI with the preview-only theme.
///
/// Uses `previewChatTheme` instead of `rcmsChatTheme` so that code blocks that
/// somehow appear in this preview don't launch `ChatHighlightedCodeView` tasks.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let isMe: Bool

    var body: some View {
        Markdown(block.raw)
            .markdownTheme(.previewChatTheme(isMe: isMe))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isMe ? Color.blue.opacity(0.12) : Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Audio Placeholder (preview only)

/// Simple non-interactive audio placeholder for the standalone preview.
/// In the real ChatRoom, `RenderedAudioBlockView` handles playback.
private struct PreviewAudioPlaceholderView: View {
    let block: AudioBlock

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            Text(block.durationLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    static func stubLoadConfig(messageID: String = "mock") -> ImageLoadConfig {
        ImageLoadConfig(
            messageID: messageID,
            imageURLString: nil,
            assetID: nil,
            assetObjectKey: nil,
            mimeType: nil,
            assetFileName: nil,
            contentName: nil
        )
    }

    private static func mockMessages() -> [RenderedMessage] {
        [
            // ── 0: Plain text ───────────────────────────────────────
            make(id: "t1", isMe: true, blocks: [
                .text(TextBlock(content: "你好！有什么我可以帮你的吗？"))
            ]),

            // ── 1: Plain prose via MarkdownBlock ─────────────────────
            make(id: "m1", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: "在 Swift 中，actor 隔离可以防止数据竞争。每个 actor 都有独立的执行上下文，外部访问其可变状态必须通过 await。"))
            ]),

            // ── 2: Bold, italic, inline code, link ───────────────────
            make(id: "m2", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: """
                **EMQX** 是一款高性能的 MQTT broker，支持 *百万级* 并发连接。\
                核心配置在 `emqx.conf` 中设置，完整文档见 [官方站点](https://www.emqx.io)。
                """))
            ]),

            // ── 3: Heading + ordered list ─────────────────────────────
            make(id: "m3", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: """
                ## 快速上手步骤

                1. 安装 Docker Desktop
                2. 克隆仓库：`git clone https://github.com/example/repo`
                3. 执行 `docker compose up --build -d`
                4. 浏览器访问 `http://localhost:3000`
                """))
            ]),

            // ── 4: Bullet list + nested ───────────────────────────────
            make(id: "m4", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: """
                支持的认证方式：

                - **JWT**：适合无状态服务
                  - HS256 / RS256 签名
                  - 可配置过期时间
                - **mTLS**：双向证书校验
                - **用户名 / 密码**：配合 PostgreSQL ACL 表
                """))
            ]),

            // ── 5: Blockquote ─────────────────────────────────────────
            make(id: "m5", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: """
                > **注意**
                > 修改 `broker/acl.conf` 之后需要重启 EMQX 容器才能生效，
                > 热重载仅对部分规则有效。

                建议在预发布环境先验证 ACL 变更再推送生产。
                """))
            ]),

            // ── 6: Multi-paragraph inline code ───────────────────────
            make(id: "m6", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: """
                `MessageRenderPipeline` 将原始 `Message` 转换为 `RenderedMessage`。

                转换结果由三种 block 类型组成：`MarkdownBlock`、`CodeBlock`、`ImageBlock`。

                所有解析逻辑在 pipeline 完成，view 层只做纯渲染，不含业务判断。
                """))
            ]),

            // ── 7: Prose + Swift code block + trailing prose ──────────
            make(id: "m7", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: "下面是一个 Swift `actor` 示例：")),
                .code(CodeBlock(
                    id: "mock-m7-cb-0",
                    language: "swift",
                    source: """
                    actor Counter {
                        private var value = 0

                        func increment() { value += 1 }
                        func get() -> Int { value }
                    }

                    let c = Counter()
                    await c.increment()
                    print(await c.get())  // 1
                    """
                )),
                .markdown(MarkdownBlock(raw: "每次访问都必须通过 `await`，隔离由编译器**静态**保证。"))
            ]),

            // ── 8: Long bash (horizontal scroll stress test) ──────────
            make(id: "c1", isMe: true, blocks: [
                .code(CodeBlock(
                    id: "mock-c1-cb-0",
                    language: "bash",
                    source: "curl -X POST https://api.example.com/v1/chat -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d '{\"message\": \"hello\", \"stream\": true}'"
                ))
            ]),

            // ── 9: Python multi-line ──────────────────────────────────
            make(id: "m9", isMe: false, blocks: [
                .markdown(MarkdownBlock(raw: "用 Python 计算 Fibonacci：")),
                .code(CodeBlock(
                    id: "mock-m9-cb-0",
                    language: "python",
                    source: """
                    def fibonacci(n: int) -> list[int]:
                        a, b = 0, 1
                        result: list[int] = []
                        while a < n:
                            result.append(a)
                            a, b = b, a + b
                        return result

                    print(fibonacci(100))
                    """
                ))
            ]),

            // ── 10: Image placeholder (with pre-computed metadata) ────
            make(id: "p1", isMe: true, blocks: [
                .image(ImageBlock(
                    altText: "截图.png",
                    loadConfig: stubLoadConfig(messageID: "p1"),
                    displaySize: CGSize(width: 240, height: 180),
                    isSticker: false,
                    aspectRatio: 4.0 / 3.0
                ))
            ]),

            // ── 11: Sticker placeholder (square aspect) ───────────────
            make(id: "p2", isMe: false, blocks: [
                .image(ImageBlock(
                    altText: "贴纸",
                    loadConfig: stubLoadConfig(messageID: "p2"),
                    displaySize: CGSize(width: 120, height: 120),
                    isSticker: true,
                    aspectRatio: 1.0
                ))
            ]),

            // ── 12: Audio (pre-computed label + bubble width) ─────────
            make(id: "p3", isMe: false, blocks: [
                .audio(AudioBlock(
                    audioURLString: nil,
                    durationSeconds: 8,
                    durationLabel: "8\"",
                    bubbleWidth: 111.6
                ))
            ]),

            // ── 13: Nil-duration audio (size-based label) ─────────────
            make(id: "p4", isMe: false, blocks: [
                .audio(AudioBlock(
                    audioURLString: nil,
                    durationSeconds: nil,
                    durationLabel: "语音",
                    bubbleWidth: 118
                ))
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

// MARK: - Preview Markdown Theme

/// A MarkdownUI `Theme` used exclusively inside `MessagePreviewView`.
///
/// Constraints vs. the production `rcmsChatTheme`:
/// - No `ChatHighlightedCodeView` — avoids the `.task` real-time highlight path.
/// - No per-token coloring — monospaced font + neutral background only.
/// - Code blocks inside this theme are a fallback guard; `MessageRenderPipeline`
///   strips all fenced code blocks before producing `MarkdownBlock` values, so
///   this handler should never fire under normal conditions.
fileprivate extension Theme {
    static func previewChatTheme(isMe: Bool) -> Theme {
        let codeBg = Color(UIColor.secondarySystemFill)

        return Theme()
            .text {
                ForegroundColor(Color(UIColor.label))
                FontSize(15)
            }
            .strong {
                FontWeight(.bold)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .code {
                FontFamily(ChatCodeTypography.markdownFontFamily)
                FontSize(13)
                BackgroundColor(codeBg)
            }
            .link {
                ForegroundColor(isMe ? Color.blue : Color.accentColor)
            }
            .paragraph { config in
                config.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 4)
            }
            .heading1 { config in
                config.label.markdownMargin(top: 6, bottom: 4)
            }
            .heading2 { config in
                config.label.markdownMargin(top: 4, bottom: 4)
            }
            .heading3 { config in
                config.label.markdownMargin(top: 4, bottom: 4)
            }
            .listItem { config in
                config.label.markdownMargin(top: 0, bottom: 2)
            }
            .blockquote { config in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(UIColor.tertiaryLabel))
                        .frame(width: 3)
                    config.label
                }
                .markdownMargin(top: 4, bottom: 4)
            }
            .codeBlock { config in
                // Fallback — should never be triggered (pipeline strips all fences)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(config.content.trimmingCharacters(in: .newlines))
                        .font(ChatCodeTypography.codeFont(size: 13))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
                .background(codeBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 4, bottom: 4)
            }
    }
}

// MARK: - Preview

#Preview {
    MessagePreviewView()
}
