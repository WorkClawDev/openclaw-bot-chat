import Foundation
import Testing
@testable import clawchat

struct BotBindingQRCodeParserTests {
    @Test func rejectsUnsupportedSchemesAndEmbeddedCredentials() {
        for url in [
            "ftp://example.test/openclaw/bind?token=ocbb_test_token_only",
            "https://user:password@example.test/openclaw/bind?token=ocbb_test_token_only",
            "javascript:ocbb_test_token_only",
        ] {
            #expect(BotBindingQRCodeParser.parse(url) == .unsupported)
        }
    }

    @Test func bindingOriginChecksSchemeHostPortAndCredentials() throws {
        let current = try #require(URL(string: "https://api.example.test"))
        #expect(ServiceEndpointConfiguration.hasSameOrigin(try #require(URL(string: "https://API.example.test:443/openclaw/bind")), current))
        for value in ["http://api.example.test", "https://other.example.test", "https://api.example.test:444", "https://user@api.example.test", "file:///api.example.test"] {
            #expect(!ServiceEndpointConfiguration.hasSameOrigin(try #require(URL(string: value)), current))
        }
    }

    @Test func parsesOneTimeBindingTokenUrl() throws {
        let token = "ocbb_abcdefghijklmnopqrstuvwxyz123456_12345678"
        let result = BotBindingQRCodeParser.parse(
            "https://api.example.test/openclaw/bind?package=%40workclawdev%2Fextension-bot-chat&channel=bot-chat&token=\(token)"
        )

        #expect(result == .bindingToken(token: token, backendURL: URL(string: "https://api.example.test")))
    }

    @Test func prefersBindingTokenOverLegacyBotId() throws {
        let token = "ocbb_abcdefghijklmnopqrstuvwxyz123456_87654321"
        let botID = UUID()
        let result = BotBindingQRCodeParser.parse(
            "https://api.example.test/openclaw/bind?token=\(token)&botId=\(botID.uuidString)"
        )

        #expect(result == .bindingToken(token: token, backendURL: URL(string: "https://api.example.test")))
    }

    @Test func stillRecognizesLegacyBotIdAndInstallUrls() throws {
        let botID = UUID()
        let botResult = BotBindingQRCodeParser.parse(
            "https://api.example.test/openclaw/bind?botId=\(botID.uuidString)"
        )
        let installResult = BotBindingQRCodeParser.parse(
            "openclaw://extensions/install?package=%40workclawdev%2Fextension-bot-chat&channel=bot-chat"
        )

        #expect(botResult == .bot(id: botID, backendURL: URL(string: "https://api.example.test")))
        #expect(installResult == .extensionInstall)
    }
}
