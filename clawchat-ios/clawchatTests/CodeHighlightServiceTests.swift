import Foundation
import Testing
@testable import clawchat

struct CodeHighlightServiceTests {

    @Test func highlightReturnsColoredAttributedString() async {
        let code = "func hello() { print(\"hi\") }"
        let result = await CodeHighlightService.shared.highlight(
            code: code,
            language: "swift",
            palette: .receivedLight
        )

        #expect(result != nil)
        #expect(result?.characters.count == code.count)

        // HighlightSwift should attach at least one foreground color attribute.
        let hasColor = result?.runs.contains { run in
            run.foregroundColor != nil
        } ?? false
        #expect(hasColor)
    }

    @Test func renderWithHighlightsPopulatesCodeHighlights() async throws {
        let payload = """
        {
          "id": "m-code-1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "text",
            "body": "Here:\\n```swift\\nlet x = 1\\n```"
          }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: payload)
        let rendered = await MessageRenderPipeline.renderWithHighlights(
            message,
            currentUserID: "u1",
            palette: .receivedLight
        )

        let codeBlocks = rendered.blocks.compactMap { block -> CodeBlock? in
            guard case .code(let cb) = block else { return nil }
            return cb
        }
        #expect(codeBlocks.count == 1)

        let blockID = codeBlocks[0].id
        #expect(rendered.codeHighlights[blockID] != nil)
    }

    @Test func parseMarkdownBodySplitsCodeFence() async throws {
        let payload = """
        {
          "id": "m-code-2",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "text",
            "body": "Intro\\n```go\\npackage main\\n```\\nOutro"
          }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(Message.self, from: payload)
        let rendered = MessageRenderPipeline.render(message, currentUserID: "u1")

        let kinds = rendered.blocks.map { block -> String in
            switch block {
            case .markdown: return "markdown"
            case .code: return "code"
            default: return "other"
            }
        }
        #expect(kinds == ["markdown", "code", "markdown"])
    }
}
