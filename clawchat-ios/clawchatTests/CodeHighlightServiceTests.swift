import Foundation
import Testing
import UIKit
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
            run.foregroundColor != nil || run.uiKit.foregroundColor != nil
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

    @Test func renderSignatureChangesWhenImageMetadataChanges() async throws {
        let basePayload = """
        {
          "id": "m-image-1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "image",
            "url": "https://example.com/image.png",
            "meta": {
              "asset": {
                "id": "asset-1",
                "width": 320,
                "height": 180
              }
            }
          }
        }
        """.data(using: .utf8)!

        let updatedPayload = """
        {
          "id": "m-image-1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "image",
            "url": "https://example.com/image.png",
            "meta": {
              "asset": {
                "id": "asset-1",
                "width": 640,
                "height": 360
              }
            }
          }
        }
        """.data(using: .utf8)!

        let baseMessage = try JSONDecoder().decode(Message.self, from: basePayload)
        let updatedMessage = try JSONDecoder().decode(Message.self, from: updatedPayload)

        let base = MessageRenderPipeline.render(baseMessage, currentUserID: "u1")
        let updated = MessageRenderPipeline.render(updatedMessage, currentUserID: "u1")

        #expect(base.renderSignature != updated.renderSignature)
    }

    @Test func renderSignatureIgnoresTextRenderMetadataChanges() async throws {
        let basePayload = """
        {
          "id": "m-text-1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "text",
            "body": "```swift\\nprint(1)\\n```",
            "meta": {
              "render_height": 120,
              "highlight_version": 1
            }
          }
        }
        """.data(using: .utf8)!

        let updatedPayload = """
        {
          "id": "m-text-1",
          "conversation_id": "c1",
          "mqtt_topic": "c1",
          "sender_id": "bot1",
          "sender_type": "bot",
          "from": { "type": "bot", "id": "bot1" },
          "to": { "type": "user", "id": "u1" },
          "content": {
            "type": "text",
            "body": "```swift\\nprint(1)\\n```",
            "meta": {
              "render_height": 148,
              "highlight_version": 2
            }
          }
        }
        """.data(using: .utf8)!

        let baseMessage = try JSONDecoder().decode(Message.self, from: basePayload)
        let updatedMessage = try JSONDecoder().decode(Message.self, from: updatedPayload)

        let base = MessageRenderPipeline.render(baseMessage, currentUserID: "u1")
        let updated = MessageRenderPipeline.render(updatedMessage, currentUserID: "u1")

        #expect(base.renderSignature == updated.renderSignature)
    }
}
