import Foundation

struct ChatPushSession: Equatable {
    let userID: UUID
    let accessToken: String
    let endpoint: URL

    var identity: String { endpoint.absoluteString + "|" + userID.uuidString }
}

struct ChatPushRoute: Equatable {
    let userID: UUID
    let conversationID: String
    let messageID: UUID
    let botID: UUID?
    let groupID: UUID?

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kind"] as? String == "chat_message",
              let user = userInfo["user_id"] as? String, let userID = UUID(uuidString: user),
              let message = userInfo["message_id"] as? String, let messageID = UUID(uuidString: message),
              let conversation = userInfo["conversation_id"] as? String else { return nil }
        let parts = conversation.lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == "chat", parts[1] == "group", let group = UUID(uuidString: parts[2]) {
            groupID = group
            botID = nil
        } else if parts.count == 6, parts[0] == "chat", parts[1] == "dm" {
            if parts[2] == "user", UUID(uuidString: parts[3]) == userID, parts[4] == "bot", let bot = UUID(uuidString: parts[5]) {
                botID = bot
            } else if parts[4] == "user", UUID(uuidString: parts[5]) == userID, parts[2] == "bot", let bot = UUID(uuidString: parts[3]) {
                botID = bot
            } else { return nil }
            groupID = nil
        } else { return nil }
        self.userID = userID
        self.messageID = messageID
        conversationID = parts.joined(separator: "/")
    }

    func shouldPresent(currentUserID: UUID?, enabled: Bool, activeConversationID: String?) -> Bool {
        enabled && currentUserID == userID && activeConversationID?.lowercased() != conversationID
    }
}

enum ChatPushError: Error, Equatable {
    case unavailable, rejected, invalidResponse
}

protocol ChatPushAPIProtocol {
    func available(session: ChatPushSession) async throws -> Bool
    func register(session: ChatPushSession, installationID: UUID, token: String, environment: String, language: String) async throws
    func revoke(session: ChatPushSession, installationID: UUID) async throws
    func resolve(route: ChatPushRoute, session: ChatPushSession) async throws -> ChatContext
}

// Every operation captures its account, credential and endpoint. A late request
// cannot accidentally use the next logged-in account or a newly selected server.
final class ChatPushAPI: ChatPushAPIProtocol {
    private let transport: URLSession
    init(transport: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.transport = transport ?? URLSession(configuration: configuration, delegate: ChatPushRedirectPolicy(), delegateQueue: nil)
    }

    func available(session: ChatPushSession) async throws -> Bool {
        struct Status: Decodable { let available: Bool }
        let status: Status = try await request("/api/v1/push/status", session: session)
        return status.available
    }

    func register(session: ChatPushSession, installationID: UUID, token: String, environment: String, language: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["token": token, "environment": environment, "language": language])
        let result: Registration = try await request("/api/v1/push/devices/\(installationID.uuidString.lowercased())", session: session, method: "PUT", body: body)
        guard result.registered else { throw ChatPushError.rejected }
    }

    func revoke(session: ChatPushSession, installationID: UUID) async throws {
        let result: Registration = try await request("/api/v1/push/devices/\(installationID.uuidString.lowercased())", session: session, method: "DELETE")
        guard !result.registered else { throw ChatPushError.rejected }
    }

    func resolve(route: ChatPushRoute, session: ChatPushSession) async throws -> ChatContext {
        guard route.userID == session.userID else { throw ChatPushError.rejected }
        // The history endpoint checks direct/group access on the server. Never
        // construct a navigable chat from an unverified notification title/URL.
        var components = URLComponents()
        components.path = "/api/v1/messages"
        components.queryItems = [URLQueryItem(name: "conversation_id", value: route.conversationID), URLQueryItem(name: "limit", value: "1")]
        let _: [IgnoredMessage] = try await request(components.string!, session: session)
        if let botID = route.botID {
            let bot: Bot = try await request("/api/v1/bots/\(botID.uuidString.lowercased())", session: session)
            guard bot.id == botID else { throw ChatPushError.invalidResponse }
            return ChatContext(id: route.conversationID, title: bot.name, subtitle: "", isGroup: false, bot: bot)
        }
        guard let groupID = route.groupID else { throw ChatPushError.invalidResponse }
        let group: ChatGroup = try await request("/api/v1/groups/\(groupID.uuidString.lowercased())", session: session)
        guard group.id == groupID, group.isActive != false else { throw ChatPushError.rejected }
        return ChatContext(id: route.conversationID, title: group.name, subtitle: "", isGroup: true, groupId: groupID.uuidString.lowercased(), memberCount: group.memberCount)
    }

    private struct Registration: Decodable { let registered: Bool }
    private struct IgnoredMessage: Decodable {}
    private struct Envelope<T: Decodable>: Decodable { let code: Int; let data: T }

    private func request<T: Decodable>(_ path: String, session: ChatPushSession, method: String = "GET", body: Data? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: session.endpoint) else { throw ChatPushError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatPushError.invalidResponse }
        if response.statusCode == 503 { throw ChatPushError.unavailable }
        guard response.statusCode == 200 else { throw ChatPushError.rejected }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw ChatPushError.invalidResponse }
            return date
        }
        let result = try decoder.decode(Envelope<T>.self, from: data)
        guard result.code == 0 else { throw ChatPushError.rejected }
        return result.data
    }
}

private final class ChatPushRedirectPolicy: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
