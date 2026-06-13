import Foundation
import Combine
import PhotosUI
import SwiftUI
import UIKit

class APIClient {
    static let shared = APIClient()
    let baseURL: URL

    private let session: URLSession
    private let remoteDataSession: URLSession

    init(session: URLSession = APIClient.makeAPISession(),
         baseURL: URL = APIClient.defaultBaseURL,
         remoteDataSession: URLSession = APIClient.makeRemoteDataSession()) {
        self.session = session
        self.baseURL = baseURL
        self.remoteDataSession = remoteDataSession
    }

    private static var defaultBaseURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-openclawApiBaseURL"),
           arguments.indices.contains(arguments.index(after: index)) {
            let rawValue = arguments[arguments.index(after: index)].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawValue.isEmpty, let url = URL(string: rawValue) {
                return url
            }
        }
        if let argument = arguments.first(where: { $0.hasPrefix("OPENCLAW_API_BASE_URL=") }) {
            let rawValue = String(argument.dropFirst("OPENCLAW_API_BASE_URL=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawValue.isEmpty, let url = URL(string: rawValue) {
                return url
            }
        }
        let rawValue = ProcessInfo.processInfo.environment["OPENCLAW_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawValue, !rawValue.isEmpty, let url = URL(string: rawValue) {
            return url
        }
        return URL(string: "https://clawchat.changer.site")!
    }

    private static func makeAPISession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }

    private static func makeRemoteDataSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 96 * 1024 * 1024,
            diskPath: "site.changer.clawchat.remote-data-cache"
        )
        return URLSession(configuration: configuration)
    }

    var brokerWebSocketFallbackURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/mqtt"
        components.query = nil
        components.fragment = nil

        return components.url
    }

    // MARK: - Auth

    func login(identifier: String, password: String) -> AnyPublisher<AuthPayload, Error> {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = LoginRequest(
            username: trimmedIdentifier.contains("@") ? nil : trimmedIdentifier,
            email: trimmedIdentifier.contains("@") ? trimmedIdentifier : nil,
            password: password
        )
        return encodedRequestWithTransportRetry("/api/v1/auth/login", method: "POST", body: payload, requiresAuth: false)
    }

    func register(username: String, email: String, password: String) -> AnyPublisher<AuthPayload, Error> {
        let payload = RegisterRequest(username: username, email: email, password: password)
        return encodedRequest("/api/v1/auth/register", method: "POST", body: payload, requiresAuth: false)
    }

    func fetchCurrentUser() -> AnyPublisher<User, Error> {
        request("/api/v1/auth/me")
    }

    func fetchCurrentUserValue() async throws -> User {
        try await requestValue("/api/v1/auth/me")
    }

    func updateProfile(nickname: String?, avatarURL: String?) async throws -> User {
        let payload = UpdateProfileRequest(nickname: nickname, avatarUrl: avatarURL)
        return try await encodedRequestValue("/api/v1/auth/me", method: "PUT", body: payload)
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        let payload = ChangePasswordRequest(oldPassword: currentPassword, newPassword: newPassword)
        let _: EmptyResponse = try await encodedRequestValue(
            "/api/v1/auth/change-password",
            method: "POST",
            body: payload
        )
    }

    func refreshTokens(refreshToken: String) -> AnyPublisher<AuthTokens, Error> {
        let payload = RefreshTokenRequest(refreshToken: refreshToken)
        return encodedRequest("/api/v1/auth/refresh", method: "POST", body: payload, requiresAuth: false)
    }

    func refreshTokensValue(refreshToken: String) async throws -> AuthTokens {
        let payload = RefreshTokenRequest(refreshToken: refreshToken)
        return try await encodedRequestValue(
            "/api/v1/auth/refresh",
            method: "POST",
            body: payload,
            requiresAuth: false
        )
    }

    // MARK: - Bots

    func fetchBots() -> AnyPublisher<[Bot], Error> {
        request("/api/v1/bots")
    }

    func fetchBotsValue() async throws -> [Bot] {
        try await requestValue("/api/v1/bots")
    }

    func createBot(name: String, description: String?, avatarURL: String?) -> AnyPublisher<Bot, Error> {
        let payload = BotMutationRequest(
            name: name,
            description: description?.isEmpty == true ? nil : description,
            avatarUrl: avatarURL?.isEmpty == true ? nil : avatarURL
        )
        return encodedRequest("/api/v1/bots", method: "POST", body: payload)
    }

    func updateBot(id: UUID, name: String, description: String?, avatarURL: String?) -> AnyPublisher<Bot, Error> {
        let payload = UpdateBotRequest(
            name: name,
            description: description?.isEmpty == true ? nil : description,
            avatarUrl: avatarURL
        )
        return encodedRequest("/api/v1/bots/\(normalized(id))", method: "PUT", body: payload)
    }

    func deleteBot(id: UUID) -> AnyPublisher<EmptyResponse, Error> {
        request("/api/v1/bots/\(normalized(id))", method: "DELETE")
    }

    func fetchBotKeys(botID: UUID) -> AnyPublisher<[BotKeyResponse], Error> {
        request("/api/v1/bots/\(normalized(botID))/keys")
    }

    func createBotKey(botID: UUID, name: String?) -> AnyPublisher<BotKeyResponse, Error> {
        let payload = CreateKeyRequest(name: name?.isEmpty == true ? nil : name, expiresAt: 0)
        return encodedRequest("/api/v1/bots/\(normalized(botID))/keys", method: "POST", body: payload)
    }

    func revokeBotKey(botID: UUID, keyID: UUID) -> AnyPublisher<EmptyResponse, Error> {
        request("/api/v1/bots/\(normalized(botID))/keys/\(normalized(keyID))", method: "DELETE")
    }

    func createBotBinding(botID: UUID) -> AnyPublisher<BotBindingResponse, Error> {
        request("/api/v1/bots/\(normalized(botID))/bindings", method: "POST")
    }

    func previewBotBinding(token: String) -> AnyPublisher<BotBindingResponse, Error> {
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        return request("/api/v1/bot-bindings/preview?token=\(encodedToken)")
    }

    func confirmBotBinding(token: String, backendURL: URL? = nil) -> AnyPublisher<BotBindingResponse, Error> {
        if let backendURL {
            return APIClient(baseURL: backendURL).confirmBotBinding(token: token)
        }
        return encodedRequest("/api/v1/bot-bindings/confirm", method: "POST", body: ConfirmBotBindingRequest(token: token))
    }

    // MARK: - Groups

    func fetchGroups() -> AnyPublisher<[ChatGroup], Error> {
        request("/api/v1/groups")
    }

    func createGroup(name: String, description: String?) -> AnyPublisher<ChatGroup, Error> {
        let payload = GroupMutationRequest(
            name: name,
            description: description?.isEmpty == true ? nil : description
        )
        return encodedRequest("/api/v1/groups", method: "POST", body: payload)
    }

    func fetchGroupMembers(groupID: String) -> AnyPublisher<GroupMembersPayload, Error> {
        request("/api/v1/groups/\(groupID)/members")
    }

    func updateGroupName(groupID: String, name: String) -> AnyPublisher<ChatGroup, Error> {
        encodedRequest("/api/v1/groups/\(groupID)", method: "PUT", body: RenameGroupRequest(name: name))
    }

    func removeGroupMember(groupID: String, memberID: UUID) -> AnyPublisher<[String: String], Error> {
        request("/api/v1/groups/\(groupID)/members/\(memberID.uuidString)", method: "DELETE")
    }

    func addBotToGroup(groupID: String, botID: UUID) -> AnyPublisher<[String: String], Error> {
        encodedRequest(
            "/api/v1/groups/\(groupID)/members",
            method: "POST",
            body: AddBotToGroupRequest(botId: botID.uuidString)
        )
    }

    // MARK: - Tasks

    func fetchTasks() async throws -> [DispatchTask] {
        try await requestValue("/api/v1/tasks")
    }

    func fetchTask(id: UUID) async throws -> DispatchTask {
        try await requestValue("/api/v1/tasks/\(normalized(id))")
    }

    func createTask(_ mutation: DispatchTaskMutation) async throws -> DispatchTask {
        try await requestValue(
            "/api/v1/tasks",
            method: "POST",
            body: mutation.jsonData()
        )
    }

    func updateTask(id: UUID, _ mutation: DispatchTaskMutation) async throws -> DispatchTask {
        try await requestValue(
            "/api/v1/tasks/\(normalized(id))",
            method: "PUT",
            body: mutation.jsonData()
        )
    }

    func dispatchTask(id: UUID, _ input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await taskAction(id: id, action: "dispatch", input: input)
    }

    func acceptTask(id: UUID, _ input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await taskAction(id: id, action: "accept", input: input)
    }

    func rejectTask(id: UUID, _ input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await taskAction(id: id, action: "reject", input: input)
    }

    func cancelTask(id: UUID, _ input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await taskAction(id: id, action: "cancel", input: input)
    }

    func retryTask(id: UUID, _ input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await taskAction(id: id, action: "retry", input: input)
    }

    func reassignTask(id: UUID, assigneeBotId: UUID?, latestStatusNote: String?) async throws -> DispatchTask {
        var body: [String: Any] = [
            "assignee_bot_id": assigneeBotId?.uuidString.lowercased() ?? NSNull()
        ]
        if let latestStatusNote, !latestStatusNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["latest_status_note"] = latestStatusNote
        }
        return try await requestValue(
            "/api/v1/tasks/\(normalized(id))/reassign",
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: body)
        )
    }

    func deleteTask(id: UUID) async throws {
        let _: EmptyResponse = try await requestValue(
            "/api/v1/tasks/\(normalized(id))",
            method: "DELETE"
        )
    }

    private func taskAction(id: UUID, action: String, input: DispatchTaskActionInput) async throws -> DispatchTask {
        try await requestValue(
            "/api/v1/tasks/\(normalized(id))/\(action)",
            method: "POST",
            body: input.jsonData()
        )
    }

    // MARK: - Conversations & Messages

    func fetchConversations() -> AnyPublisher<[Conversation], Error> {
        request("/api/v1/conversations")
    }

    func fetchMessages(conversationID: String,
                       limit: Int,
                       beforeSeq: Int? = nil,
                       afterSeq: Int? = nil) async throws -> [Message] {
        try await requestValue(messageEndpoint(
            conversationID: conversationID,
            limit: limit,
            beforeSeq: beforeSeq,
            afterSeq: afterSeq
        ))
    }

    // MARK: - Documents

    func fetchDocuments(limit: Int = 100) async throws -> [DocumentObject] {
        try await requestValue("/api/v1/documents?limit=\(max(1, min(limit, 200)))")
    }

    func fetchDocument(id: UUID) async throws -> DocumentObject {
        try await requestValue("/api/v1/documents/\(normalized(id))")
    }

    func createDocument(title: String, body: String, summary: String? = nil) async throws -> DocumentObject {
        try await encodedRequestValue(
            "/api/v1/documents",
            method: "POST",
            body: DocumentMutationRequest(
                title: title,
                body: body,
                summary: summary,
                documentType: "markdown",
                source: "user",
                conversationId: nil
            )
        )
    }

    func updateDocument(id: UUID, title: String, body: String, summary: String? = nil) async throws -> DocumentObject {
        try await encodedRequestValue(
            "/api/v1/documents/\(normalized(id))",
            method: "PUT",
            body: DocumentMutationRequest(
                title: title,
                body: body,
                summary: summary,
                documentType: nil,
                source: nil,
                conversationId: nil
            )
        )
    }

    func archiveDocument(id: UUID) async throws {
        let _: EmptyResponse = try await requestValue(
            "/api/v1/documents/\(normalized(id))",
            method: "DELETE"
        )
    }

    // MARK: - Realtime

    func fetchRealtimeBootstrap() -> AnyPublisher<RealtimeBootstrapResponse, Error> {
        request("/api/v1/realtime/bootstrap")
    }

    // MARK: - Remote Assets

    func fetchRemoteData(from url: URL,
                         acceptHeader: String? = nil,
                         timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        request.timeoutInterval = timeout
        if let acceptHeader {
            request.addValue(acceptHeader, forHTTPHeaderField: "Accept")
        }

        let (data, response) = try await remoteDataSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw APIError.serverError("Failed to load remote asset")
        }
        return data
    }

    enum APIError: LocalizedError {
        case invalidURL
        case noData
        case decodingError
        case serverError(String)
        case unauthorized
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL"
            case .noData:
                return "No data received from server"
            case .decodingError:
                return "Failed to parse server response"
            case .serverError(let message):
                return message
            case .unauthorized:
                return "Session expired or invalid credentials"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            let raw = try container.decode(String.self)
            let iso8601 = ISO8601DateFormatter()
            iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso8601.date(from: raw) {
                return date
            }

            let fallbackISO = ISO8601DateFormatter()
            fallbackISO.formatOptions = [.withInternetDateTime]
            if let date = fallbackISO.date(from: raw) {
                return date
            }

            throw APIError.decodingError
        }
        return decoder
    }()

    func request<T: Codable>(_ endpoint: String,
                            method: String = "GET",
                            body: Data? = nil,
                            requiresAuth: Bool = true) -> AnyPublisher<T, Error> {
        request(endpoint, method: method, body: body, requiresAuth: requiresAuth, allowRefresh: true)
    }

    private func encodedRequest<T: Codable, Body: Encodable>(_ endpoint: String,
                                                             method: String = "GET",
                                                             body: Body,
                                                             requiresAuth: Bool = true) -> AnyPublisher<T, Error> {
        do {
            return request(
                endpoint,
                method: method,
                body: try JSONEncoder().encode(body),
                requiresAuth: requiresAuth
            )
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    private func encodedRequestWithTransportRetry<T: Codable, Body: Encodable>(_ endpoint: String,
                                                                               method: String = "GET",
                                                                               body: Body,
                                                                               requiresAuth: Bool = true) -> AnyPublisher<T, Error> {
        do {
            let encodedBody = try JSONEncoder().encode(body)
            return request(
                endpoint,
                method: method,
                body: encodedBody,
                requiresAuth: requiresAuth
            )
            .catch { [weak self] error -> AnyPublisher<T, Error> in
                guard let self, Self.isRetryableTransportError(error) else {
                    return Fail(error: error).eraseToAnyPublisher()
                }

                return self.request(
                    endpoint,
                    method: method,
                    body: encodedBody,
                    requiresAuth: requiresAuth
                )
            }
            .eraseToAnyPublisher()
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    private func request<T: Codable>(_ endpoint: String,
                                     method: String = "GET",
                                     body: Data? = nil,
                                     requiresAuth: Bool = true,
                                     allowRefresh: Bool) -> AnyPublisher<T, Error> {
        requestOnce(endpoint, method: method, body: body, requiresAuth: requiresAuth)
            .catch { [weak self] error -> AnyPublisher<T, Error> in
                guard let self,
                      requiresAuth,
                      allowRefresh,
                      Self.isUnauthorized(error) else {
                    return Fail(error: error).eraseToAnyPublisher()
                }

                return AuthManager.shared.refreshSessionPublisher()
                    .flatMap { _ in
                        self.request(
                            endpoint,
                            method: method,
                            body: body,
                            requiresAuth: requiresAuth,
                            allowRefresh: false
                        )
                    }
                    .handleEvents(receiveCompletion: { completion in
                        if case .failure(let retryError) = completion,
                           Self.isUnauthorized(retryError) {
                            AuthManager.shared.logout()
                        }
                    })
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    private func requestOnce<T: Codable>(_ endpoint: String,
                                         method: String = "GET",
                                         body: Data? = nil,
                                         requiresAuth: Bool = true) -> AnyPublisher<T, Error> {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            return Fail(error: APIError.invalidURL).eraseToAnyPublisher()
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }
        request.httpBody = body

        if requiresAuth, let token = AuthManager.shared.accessToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return session.dataTaskPublisher(for: request)
            .mapError { APIError.networkError($0) }
            .tryMap { data, response -> Data in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.serverError("Invalid response from server")
                }

                if httpResponse.statusCode == 401 {
                    throw APIError.unauthorized
                }

                if !(200...299).contains(httpResponse.statusCode) {
                    // Try to parse error message from ApiResponse
                    if let apiError = try? Self.decoder.decode(ApiResponse<EmptyResponse>.self, from: data) {
                        throw APIError.serverError(apiError.message)
                    }
                    
                    let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                    throw APIError.serverError(errorMessage)
                }

                return data
            }
            .decode(type: ApiResponse<T>.self, decoder: Self.decoder)
            .tryMap { apiResponse -> T in
                if apiResponse.code != 0 {
                    throw APIError.serverError(apiResponse.message)
                }
                guard let data = apiResponse.data else {
                    if T.self == EmptyResponse.self {
                        return EmptyResponse() as! T
                    }
                    throw APIError.noData
                }
                return data
            }
            .eraseToAnyPublisher()
    }

    struct EmptyResponse: Codable {}

    func requestValue<T: Codable>(_ endpoint: String,
                                  method: String = "GET",
                                  body: Data? = nil,
                                  requiresAuth: Bool = true) async throws -> T {
        do {
            return try await requestValueOnce(endpoint, method: method, body: body, requiresAuth: requiresAuth)
        } catch {
            guard requiresAuth, Self.isUnauthorized(error) else {
                throw error
            }

            try await AuthManager.shared.refreshSession()
            do {
                return try await requestValueOnce(endpoint, method: method, body: body, requiresAuth: requiresAuth)
            } catch {
                if Self.isUnauthorized(error) {
                    await MainActor.run {
                        AuthManager.shared.logout()
                    }
                }
                throw error
            }
        }
    }

    private func encodedRequestValue<T: Codable, Body: Encodable>(_ endpoint: String,
                                                                  method: String = "GET",
                                                                  body: Body,
                                                                  requiresAuth: Bool = true) async throws -> T {
        try await requestValue(
            endpoint,
            method: method,
            body: try JSONEncoder().encode(body),
            requiresAuth: requiresAuth
        )
    }

    private func requestValueOnce<T: Codable>(_ endpoint: String,
                                             method: String = "GET",
                                             body: Data? = nil,
                                             requiresAuth: Bool = true) async throws -> T {
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if #available(iOS 14.5, *) {
            request.assumesHTTP3Capable = false
        }
        request.httpBody = body

        if requiresAuth, let token = AuthManager.shared.accessToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.serverError("Invalid response from server")
            }

            if httpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }

            if !(200...299).contains(httpResponse.statusCode) {
                // Try to parse error message from ApiResponse
                if let apiError = try? Self.decoder.decode(ApiResponse<EmptyResponse>.self, from: data) {
                    throw APIError.serverError(apiError.message)
                }
                
                let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw APIError.serverError(errorMessage)
            }

            let apiResponse = try Self.decoder.decode(ApiResponse<T>.self, from: data)
            if apiResponse.code != 0 {
                throw APIError.serverError(apiResponse.message)
            }

            guard let payload = apiResponse.data else {
                if T.self == EmptyResponse.self {
                    return EmptyResponse() as! T
                }
                throw APIError.noData
            }

            return payload
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case APIError.unauthorized = error {
            return true
        }
        return false
    }

    private static func isRetryableTransportError(_ error: Error) -> Bool {
        guard case APIError.networkError(let underlying) = error,
              let urlError = underlying as? URLError
        else {
            return false
        }

        switch urlError.code {
        case .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func messageEndpoint(conversationID: String,
                                 limit: Int,
                                 beforeSeq: Int? = nil,
                                 afterSeq: Int? = nil) -> String {
        var endpoint = "/api/v1/messages/\(conversationID)?limit=\(max(1, min(limit, 200)))"
        if let beforeSeq {
            endpoint += "&before_seq=\(beforeSeq)"
        }
        if let afterSeq {
            endpoint += "&after_seq=\(afterSeq)"
        }
        return endpoint
    }

    private func normalized(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    func prepareImageUpload(fileName: String,
                            contentType: String,
                            size: Int,
                            conversationID: String?) async throws -> PreparedUpload {
        try await encodedRequestValue(
            "/api/v1/assets/image/upload-prepare",
            method: "POST",
            body: PrepareImageUploadRequest(
                fileName: fileName,
                contentType: contentType,
                size: size,
                conversationId: conversationID
            )
        )
    }

    func completeImageUpload(assetID: String, objectKey: String) async throws -> Asset {
        try await encodedRequestValue(
            "/api/v1/assets/image/complete",
            method: "POST",
            body: CompleteImageUploadRequest(assetId: assetID, objectKey: objectKey)
        )
    }

    func uploadImageData(_ data: Data, with upload: PresignedUpload) async throws {
        guard let url = URL(string: upload.url) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = upload.method.isEmpty ? "PUT" : upload.method
        request.timeoutInterval = 60
        request.httpBody = data

        upload.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.serverError("Invalid upload response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.serverError("Upload failed with status \(httpResponse.statusCode)")
        }
    }

    func publicImageURL(assetID: String) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("assets")
            .appendingPathComponent("image")
            .appendingPathComponent(assetID)
    }

    func resolvedURL(from rawValue: String?) -> URL? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        if trimmed.hasPrefix("//") {
            return URL(string: "\(baseURL.scheme ?? "https"):\(trimmed)")
        }

        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}

enum AvatarUploadError: LocalizedError {
    case unreadableImage
    case unsupportedImage
    case invalidUploadResponse

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Could not read the selected image"
        case .unsupportedImage:
            return "Please choose a valid image"
        case .invalidUploadResponse:
            return "Avatar upload completed without a usable asset"
        }
    }
}

struct AvatarUploadService {
    private static let avatarSize = CGSize(width: 512, height: 512)
    private static let mimeType = "image/png"

    static func uploadAvatar(from item: PhotosPickerItem, fileNamePrefix: String) async throws -> String {
        let image = try await loadImage(from: item)
        return try await uploadAvatarImage(image, fileNamePrefix: fileNamePrefix)
    }

    static func loadImage(from item: PhotosPickerItem) async throws -> UIImage {
        guard let rawData = try await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            throw AvatarUploadError.unreadableImage
        }

        guard let image = UIImage(data: rawData) else {
            throw AvatarUploadError.unsupportedImage
        }

        return image
    }

    static func uploadAvatarImage(_ image: UIImage, fileNamePrefix: String) async throws -> String {
        guard let pngData = squarePNGData(from: image) else {
            throw AvatarUploadError.unsupportedImage
        }

        let preparedUpload = try await APIClient.shared.prepareImageUpload(
            fileName: avatarFileName(prefix: fileNamePrefix),
            contentType: mimeType,
            size: pngData.count,
            conversationID: nil
        )

        try await APIClient.shared.uploadImageData(pngData, with: preparedUpload.upload)

        let assetID = preparedUpload.asset.id ?? ""
        let objectKey = preparedUpload.asset.objectKey ?? ""
        guard !assetID.isEmpty, !objectKey.isEmpty else {
            throw AvatarUploadError.invalidUploadResponse
        }

        let asset = try await APIClient.shared.completeImageUpload(assetID: assetID, objectKey: objectKey)
        guard let completedAssetID = asset.id, !completedAssetID.isEmpty else {
            throw AvatarUploadError.invalidUploadResponse
        }

        return APIClient.shared.publicImageURL(assetID: completedAssetID).absoluteString
    }

    private static func squarePNGData(from image: UIImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return nil
        }

        let shortestSide = min(sourceSize.width, sourceSize.height)
        let sourceRect = CGRect(
            x: (sourceSize.width - shortestSide) / 2,
            y: (sourceSize.height - shortestSide) / 2,
            width: shortestSide,
            height: shortestSide
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: avatarSize, format: format)
        let renderedImage = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: avatarSize))
            let scale = avatarSize.width / shortestSide
            image.draw(in: CGRect(
                x: -sourceRect.minX * scale,
                y: -sourceRect.minY * scale,
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            ))
        }

        return renderedImage.pngData()
    }

    private static func avatarFileName(prefix: String) -> String {
        let cleanedPrefix = prefix
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let safePrefix = cleanedPrefix.isEmpty ? "avatar" : cleanedPrefix
        return "\(safePrefix)-avatar-\(UUID().uuidString.lowercased()).png"
    }
}

class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated: Bool = false
    @Published var currentUser: User? {
        didSet {
            persistCurrentUser()
            prefetchCurrentUserAvatar()
        }
    }

    private let userDefaults = UserDefaults.standard
    private let accessTokenKey = "access_token"
    private let refreshTokenKey = "refresh_token"
    private let currentUserKey = "current_user"
    private var cancellables = Set<AnyCancellable>()
    private var isRefreshingCurrentUser = false

    var accessToken: String? {
        userDefaults.string(forKey: accessTokenKey)
    }

    private var refreshToken: String? {
        userDefaults.string(forKey: refreshTokenKey)
    }

    init() {
        self.isAuthenticated = accessToken != nil
        if isAuthenticated {
            self.currentUser = Self.decodeCachedUser(from: userDefaults.data(forKey: currentUserKey))
            prefetchCurrentUserAvatar()
        }
    }

    func refreshCurrentUserIfNeeded(force: Bool = false) {
        guard isAuthenticated else { return }
        guard force || currentUser == nil else { return }
        guard !isRefreshingCurrentUser else { return }

        isRefreshingCurrentUser = true

        APIClient.shared.fetchCurrentUser()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isRefreshingCurrentUser = false
                if case .failure(let error) = completion {
                    print("Failed to refresh current user: \(error.localizedDescription)")
                }
            } receiveValue: { [weak self] (user: User) in
                self?.currentUser = user
                self?.isAuthenticated = true
            }
            .store(in: &cancellables)
    }

    func login(payload: AuthPayload) {
        store(tokens: payload.tokens)
        self.currentUser = payload.user
    }

    func refreshSessionPublisher() -> AnyPublisher<Void, Error> {
        guard let refreshToken else {
            logout()
            return Fail(error: APIClient.APIError.unauthorized).eraseToAnyPublisher()
        }

        return APIClient.shared.refreshTokens(refreshToken: refreshToken)
            .receive(on: DispatchQueue.main)
            .handleEvents(
                receiveOutput: { [weak self] tokens in
                    self?.store(tokens: tokens)
                },
                receiveCompletion: { [weak self] completion in
                    if case .failure = completion {
                        self?.logout()
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func refreshSession() async throws {
        guard let refreshToken else {
            await MainActor.run {
                logout()
            }
            throw APIClient.APIError.unauthorized
        }

        do {
            let tokens = try await APIClient.shared.refreshTokensValue(refreshToken: refreshToken)

            await MainActor.run {
                store(tokens: tokens)
            }
        } catch {
            await MainActor.run {
                logout()
            }
            throw error
        }
    }

    func logout() {
        userDefaults.removeObject(forKey: accessTokenKey)
        userDefaults.removeObject(forKey: refreshTokenKey)
        userDefaults.removeObject(forKey: currentUserKey)
        self.currentUser = nil
        self.isAuthenticated = false
        RealtimeService.shared.stop()
    }

    private func store(tokens: AuthTokens) {
        userDefaults.set(tokens.accessToken, forKey: accessTokenKey)
        userDefaults.set(tokens.refreshToken, forKey: refreshTokenKey)
        self.isAuthenticated = true
    }

    private func persistCurrentUser() {
        guard let currentUser else {
            userDefaults.removeObject(forKey: currentUserKey)
            return
        }

        guard let data = try? JSONEncoder().encode(currentUser) else {
            return
        }
        userDefaults.set(data, forKey: currentUserKey)
    }

    private func prefetchCurrentUserAvatar() {
        guard let avatar = currentUser?.avatarUrl ?? currentUser?.avatar,
              let url = APIClient.shared.resolvedURL(from: avatar)
        else {
            return
        }
        AvatarImagePrefetcher.prefetch([url])
    }

    private static func decodeCachedUser(from data: Data?) -> User? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }
}

private struct RefreshTokenRequest: Codable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct LoginRequest: Codable {
    let username: String?
    let email: String?
    let password: String
}

private struct RegisterRequest: Codable {
    let username: String
    let email: String
    let password: String
}

private struct BotMutationRequest: Codable {
    let name: String
    let description: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, description
        case avatarUrl = "avatar_url"
    }
}

private struct GroupMutationRequest: Codable {
    let name: String
    let description: String?
}

private struct RenameGroupRequest: Codable {
    let name: String
}

private struct AddBotToGroupRequest: Codable {
    let botId: String

    enum CodingKeys: String, CodingKey {
        case botId = "bot_id"
    }
}

private struct ConfirmBotBindingRequest: Codable {
    let token: String
}
