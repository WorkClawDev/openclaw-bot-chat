import Foundation

// MARK: - Core Entities

struct User: Codable, Identifiable {
    let id: UUID
    var username: String
    var email: String
    var nickname: String?
    var avatar: String?
    var avatarUrl: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, username, email, nickname, avatar
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct Bot: Codable, Identifiable {
    let id: UUID
    var ownerId: UUID?
    var name: String
    var description: String?
    var avatar: String?
    var avatarUrl: String?
    var botType: String?
    var status: String?
    var mqttTopic: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description, avatar, status
        case ownerId = "owner_id"
        case avatarUrl = "avatar_url"
        case botType = "bot_type"
        case mqttTopic = "mqtt_topic"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Bot Management Requests & Responses

struct UpdateBotRequest: Codable {
    let name: String?
    let description: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case name, description
        case avatarUrl = "avatar_url"
    }
}

struct BotKeyResponse: Codable, Identifiable {
    let id: UUID
    var keyPrefix: String
    var name: String?
    var key: String? // Only present when creating a new key
    var lastUsedAt: Date?
    var lastUsedIp: String?
    var expiresAt: Date?
    var isActive: Bool
    
    enum CodingKeys: String, CodingKey {
        case id, name, key
        case keyPrefix = "key_prefix"
        case lastUsedAt = "last_used_at"
        case lastUsedIp = "last_used_ip"
        case expiresAt = "expires_at"
        case isActive = "is_active"
    }
}

struct CreateKeyRequest: Codable {
    let name: String?
    let expiresAt: Int64?
    
    enum CodingKeys: String, CodingKey {
        case name
        case expiresAt = "expires_at"
    }
}

struct ChatGroup: Codable, Identifiable {
    let id: UUID
    var name: String
    var description: String?
    var avatar: String?
    var avatarUrl: String?
    var ownerId: UUID
    var memberCount: Int?
    var isActive: Bool?
    var mqttTopic: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description, avatar
        case avatarUrl = "avatar_url"
        case ownerId = "owner_id"
        case memberCount = "member_count"
        case isActive = "is_active"
        case mqttTopic = "mqtt_topic"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Group Member Models

struct GroupMembersPayload: Codable {
    let users: [GroupUserMember]
    let bots: [GroupBotMember]
}

struct GroupUserMember: Codable, Identifiable {
    let id: UUID
    let groupId: UUID
    let userId: UUID
    let role: String
    let nickname: String?
    let user: User?

    enum CodingKeys: String, CodingKey {
        case id, role, nickname, user
        case groupId = "group_id"
        case userId = "user_id"
    }
}

struct GroupBotMember: Codable, Identifiable {
    let id: UUID
    let groupId: UUID
    let botId: UUID
    let role: String
    let nickname: String?
    let bot: Bot?

    enum CodingKeys: String, CodingKey {
        case id, role, nickname, bot
        case groupId = "group_id"
        case botId = "bot_id"
    }
}

// MARK: - Chat & Messages

struct ChatPeer: Codable {
    let type: String
    let id: String
    var name: String?
    var avatar: String?
}

struct Asset: Codable {
    var id: String?
    var kind: String?
    var status: String?
    var storageProvider: String?
    var bucket: String?
    var objectKey: String?
    var mimeType: String?
    var size: Int?
    var fileName: String?
    var width: Int?
    var height: Int?
    var sha256: String?
    var downloadURL: String?
    var downloadURLExpiresAt: Date?
    var externalURL: String?
    var sourceURL: String?
    var metadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id, kind, status, bucket, size, width, height, sha256, metadata
        case storageProvider = "storage_provider"
        case objectKey = "object_key"
        case mimeType = "mime_type"
        case fileName = "file_name"
        case downloadURL = "download_url"
        case downloadURLExpiresAt = "download_url_expires_at"
        case externalURL = "external_url"
        case sourceURL = "source_url"
    }
}

struct PreparedUpload: Codable {
    let asset: Asset
    let upload: PresignedUpload
}

struct PresignedUpload: Codable {
    let method: String
    let url: String
    let headers: [String: String]?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case method, url, headers
        case expiresAt = "expires_at"
    }
}

struct PrepareImageUploadRequest: Codable {
    let fileName: String
    let contentType: String
    let size: Int
    let conversationId: String?

    enum CodingKeys: String, CodingKey {
        case size
        case fileName = "file_name"
        case contentType = "content_type"
        case conversationId = "conversation_id"
    }
}

struct CompleteImageUploadRequest: Codable {
    let assetId: String
    let objectKey: String

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case objectKey = "object_key"
    }
}

struct MessageContent: Codable {
    var type: String
    var body: String?
    var url: String?
    var name: String?
    var size: Int?
    var meta: [String: AnyCodable]?
}

struct Message: Codable, Identifiable {
    let id: String
    var conversationId: String
    var topic: String
    var senderId: String
    var senderType: String
    var from: ChatPeer
    var to: ChatPeer
    var content: MessageContent
    var seq: Int?
    var timestamp: Int64?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, from, to, content, seq, timestamp
        case conversationId = "conversation_id"
        case topic = "mqtt_topic"
        case senderId = "sender_id"
        case senderType = "sender_type"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        conversationId = try container.decode(String.self, forKey: .conversationId)
        
        // Topic might come from mqtt_topic or be missing, fallback to conversationId
        if let topicVal = try? container.decodeIfPresent(String.self, forKey: .topic) {
            topic = topicVal
        } else {
            topic = conversationId
        }

        from = try container.decode(ChatPeer.self, forKey: .from)
        to = try container.decode(ChatPeer.self, forKey: .to)
        content = try container.decode(MessageContent.self, forKey: .content)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        
        if let sId = try? container.decodeIfPresent(String.self, forKey: .senderId) {
            senderId = sId
        } else {
            senderId = from.id
        }
        
        if let sType = try? container.decodeIfPresent(String.self, forKey: .senderType) {
            senderType = sType
        } else {
            senderType = from.type
        }
    }
}

struct Conversation: Codable, Identifiable {
    let id: String
    var type: String
    var name: String
    var avatar: String?
    var targetId: String?
    var lastMessage: MessageSnippet?
    var unreadCount: Int?

    struct MessageSnippet: Codable {
        var content: String?
        var timestamp: Int64?
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, avatar
        case targetId = "targetId"
        case lastMessage = "lastMessage"
        case unreadCount = "unreadCount"
    }
}

// MARK: - Display Helpers

extension Message {
    var displayDate: Date? {
        if let createdAt {
            return createdAt
        }
        guard let timestamp else {
            return nil
        }

        let normalizedTimestamp = timestamp > 1_000_000_000_000 ? Double(timestamp) / 1000 : Double(timestamp)
        return Date(timeIntervalSince1970: normalizedTimestamp)
    }
}

extension Conversation.MessageSnippet {
    var displayDate: Date? {
        guard let timestamp else {
            return nil
        }

        let normalizedTimestamp = timestamp > 1_000_000_000_000 ? Double(timestamp) / 1000 : Double(timestamp)
        return Date(timeIntervalSince1970: normalizedTimestamp)
    }
}

// MARK: - Realtime Models

struct BrokerInfo: Codable {
    let wsPublicURL: String
    let username: String?
    let password: String?
    let qos: Int?

    enum CodingKeys: String, CodingKey {
        case wsPublicURL = "ws_url"
        case username, password, qos
    }
}

struct RealtimeSubscription: Codable {
    let topic: String
    let qos: Int
}

struct RealtimeHistoryInfo: Codable {
    let maxCatchupBatch: Int

    enum CodingKeys: String, CodingKey {
        case maxCatchupBatch = "max_catchup_batch"
    }
}

struct RealtimeBootstrapResponse: Codable {
    let broker: BrokerInfo
    let clientId: String
    let principalType: String
    let principalId: String
    let subscriptions: [RealtimeSubscription]
    let publishTopics: [String]
    let slashCommandTopic: String?
    let slashAutocompleteRequestTopic: String?
    let slashAutocompleteResponseTopic: String?
    let history: RealtimeHistoryInfo

    enum CodingKeys: String, CodingKey {
        case broker, subscriptions, history
        case clientId = "client_id"
        case principalType = "principal_type"
        case principalId = "principal_id"
        case publishTopics = "publish_topics"
        case slashCommandTopic = "slash_command_topic"
        case slashAutocompleteRequestTopic = "slash_autocomplete_request_topic"
        case slashAutocompleteResponseTopic = "slash_autocomplete_response_topic"
    }
}

struct SlashCommandChoice: Identifiable {
    var id: String { value }
    let label: String
    let value: String
    let description: String?
}

struct SlashCommandArg: Identifiable {
    var id: String { name }
    let name: String
    let description: String?
    let type: String?
    let required: Bool
    let choices: [SlashCommandChoice]?
}

struct SlashCommand: Identifiable {
    var id: String { name.lowercased() }
    let name: String
    let description: String?
    let acceptsArgs: Bool
    let args: [SlashCommandArg]?

    nonisolated static func catalog(from meta: [String: AnyCodable]?) -> [SlashCommand] {
        guard let rawItems = meta?["slash_commands"]?.arrayValue else {
            return []
        }

        return rawItems.compactMap { item in
            guard let dictionary = item.dictionaryValue else { return nil }
            return SlashCommand(meta: dictionary)
        }
    }

    nonisolated private init?(meta: [String: AnyCodable]) {
        let cleanedName = meta["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        let rawName = String(cleanedName.drop(while: { $0 == "/" }))
        guard !rawName.isEmpty else {
            return nil
        }

        let parsedArgs = SlashCommandArg.catalog(from: meta["args"]?.arrayValue)
        self.name = rawName
        self.description = meta["description"]?.stringValue
        self.acceptsArgs = meta["acceptsArgs"]?.boolValue
            ?? meta["accepts_args"]?.boolValue
            ?? !(parsedArgs?.isEmpty ?? true)
        self.args = parsedArgs
    }
}

extension SlashCommandArg {
    nonisolated static func catalog(from rawItems: [AnyCodable]?) -> [SlashCommandArg]? {
        guard let rawItems else { return nil }
        let args = rawItems.compactMap { item -> SlashCommandArg? in
            guard let dictionary = item.dictionaryValue else { return nil }
            let rawName = dictionary["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawName, !rawName.isEmpty else { return nil }
            return SlashCommandArg(
                name: rawName,
                description: dictionary["description"]?.stringValue,
                type: dictionary["type"]?.stringValue,
                required: dictionary["required"]?.boolValue == true,
                choices: SlashCommandChoice.catalog(from: dictionary["choices"]?.arrayValue)
            )
        }
        return args.isEmpty ? nil : args
    }
}

extension SlashCommandChoice {
    nonisolated static func catalog(from rawItems: [AnyCodable]?) -> [SlashCommandChoice]? {
        guard let rawItems else { return nil }
        let choices = rawItems.compactMap(SlashCommandChoice.init(value:))
        return choices.isEmpty ? nil : choices
    }

    nonisolated private init?(value: AnyCodable) {
        if let dictionary = value.dictionaryValue {
            let rawValue = Self.stringValue(
                dictionary["value"] ?? dictionary["id"] ?? dictionary["name"] ?? dictionary["label"]
            )
            let rawLabel = Self.stringValue(dictionary["name"] ?? dictionary["label"] ?? dictionary["title"])
            guard let rawValue, !rawValue.isEmpty else { return nil }
            self.value = rawValue
            self.label = rawLabel?.isEmpty == false ? rawLabel! : rawValue
            self.description = dictionary["description"]?.stringValue ?? dictionary["summary"]?.stringValue
            return
        }

        guard let rawValue = Self.stringValue(value), !rawValue.isEmpty else {
            return nil
        }
        self.value = rawValue
        self.label = rawValue
        self.description = nil
    }

    nonisolated private static func stringValue(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let bool = value.boolValue {
            return String(bool)
        }
        if let int = value.value as? Int {
            return String(int)
        }
        if let double = value.value as? Double {
            return String(double)
        }
        return nil
    }
}

struct MessagePeerPayload: Codable {
    let type: String
    let id: String
    var name: String?
    var avatar: String?
}

struct RealtimeContentPayload: Codable {
    let type: String
    let body: String?
    var url: String?
    var name: String?
    var size: Int?
    var meta: [String: AnyCodable]?
}

struct RealtimeMessagePayload: Codable {
    let id: String
    let topic: String
    let conversationId: String
    let timestamp: Int64
    let from: MessagePeerPayload
    let to: MessagePeerPayload
    let content: RealtimeContentPayload
    var seq: Int64?

    enum CodingKeys: String, CodingKey {
        case id, topic, timestamp, from, to, content, seq
        case messageId = "message_id"
        case conversationId = "conversation_id"
    }

    init(id: String,
         topic: String,
         conversationId: String,
         timestamp: Int64,
         from: MessagePeerPayload,
         to: MessagePeerPayload,
         content: RealtimeContentPayload,
         seq: Int64?) {
        self.id = id
        self.topic = topic
        self.conversationId = conversationId
        self.timestamp = timestamp
        self.from = from
        self.to = to
        self.content = content
        self.seq = seq
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decode(String.self, forKey: .messageId)
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId) ?? topic
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
        from = try container.decode(MessagePeerPayload.self, forKey: .from)
        to = try container.decode(MessagePeerPayload.self, forKey: .to)
        content = try container.decode(RealtimeContentPayload.self, forKey: .content)
        seq = try container.decodeIfPresent(Int64.self, forKey: .seq)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(topic, forKey: .topic)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(seq, forKey: .seq)
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        if value is NSNull {
            self.value = NSNull()
        } else {
            self.value = value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let array = try? container.decode([AnyCodable].self) { value = array }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if value is NSNull { try container.encodeNil() }
        else if let str = value as? String { try container.encode(str) }
        else if let int = value as? Int { try container.encode(int) }
        else if let double = value as? Double { try container.encode(double) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else if let dict = value as? [String: AnyCodable] { try container.encode(dict) }
        else if let array = value as? [AnyCodable] { try container.encode(array) }
    }
}

extension AnyCodable {
    var stringValue: String? {
        value as? String
    }

    var boolValue: Bool? {
        value as? Bool
    }

    var intValue: Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double {
            return Int(double)
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    var dictionaryValue: [String: AnyCodable]? {
        value as? [String: AnyCodable]
    }

    var arrayValue: [AnyCodable]? {
        value as? [AnyCodable]
    }

    var jsonObject: Any {
        if let dictionaryValue {
            return dictionaryValue.mapValues(\.jsonObject)
        }

        if let array = arrayValue {
            return array.map(\.jsonObject)
        }

        return value
    }
}

extension Asset {
    var preferredImageURLString: String? {
        let candidates = [downloadURL, externalURL, sourceURL]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    var metaValue: AnyCodable {
        var dictionary: [String: AnyCodable] = [:]

        if let id, !id.isEmpty {
            dictionary["id"] = AnyCodable(id)
        }
        if let kind, !kind.isEmpty {
            dictionary["kind"] = AnyCodable(kind)
        }
        if let status, !status.isEmpty {
            dictionary["status"] = AnyCodable(status)
        }
        if let storageProvider, !storageProvider.isEmpty {
            dictionary["storage_provider"] = AnyCodable(storageProvider)
        }
        if let bucket, !bucket.isEmpty {
            dictionary["bucket"] = AnyCodable(bucket)
        }
        if let objectKey, !objectKey.isEmpty {
            dictionary["object_key"] = AnyCodable(objectKey)
        }
        if let mimeType, !mimeType.isEmpty {
            dictionary["mime_type"] = AnyCodable(mimeType)
        }
        if let size {
            dictionary["size"] = AnyCodable(size)
        }
        if let fileName, !fileName.isEmpty {
            dictionary["file_name"] = AnyCodable(fileName)
        }
        if let width {
            dictionary["width"] = AnyCodable(width)
        }
        if let height {
            dictionary["height"] = AnyCodable(height)
        }
        if let sha256, !sha256.isEmpty {
            dictionary["sha256"] = AnyCodable(sha256)
        }
        if let downloadURL, !downloadURL.isEmpty {
            dictionary["download_url"] = AnyCodable(downloadURL)
        }
        if let downloadURLExpiresAt {
            dictionary["download_url_expires_at"] = AnyCodable(Self.assetDateFormatter.string(from: downloadURLExpiresAt))
        }
        if let externalURL, !externalURL.isEmpty {
            dictionary["external_url"] = AnyCodable(externalURL)
        }
        if let sourceURL, !sourceURL.isEmpty {
            dictionary["source_url"] = AnyCodable(sourceURL)
        }
        if let metadata, !metadata.isEmpty {
            dictionary["metadata"] = AnyCodable(metadata)
        }

        return AnyCodable(dictionary)
    }

    static func from(meta: [String: AnyCodable]?) -> Asset? {
        guard let assetMeta = meta?["asset"]?.dictionaryValue else {
            return nil
        }

        let jsonObject = assetMeta.mapValues(\.jsonObject)
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            return nil
        }

        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject) else {
            return nil
        }

        return try? Self.assetJSONDecoder.decode(Asset.self, from: data)
    }

    private static let assetDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let assetJSONDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }

            let raw = try container.decode(String.self)
            if let date = Asset.assetDateFormatter.date(from: raw) {
                return date
            }

            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]
            if let date = fallbackFormatter.date(from: raw) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid asset date"
            )
        }
        return decoder
    }()
}

extension MessageContent {
    var asset: Asset? {
        Asset.from(meta: meta)
    }

    var imageURLString: String? {
        let directURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directURL, !directURL.isEmpty {
            return directURL
        }
        return asset?.preferredImageURLString
    }

    var isSticker: Bool {
        meta?["is_sticker"]?.boolValue == true
    }
}

extension Message {
    init(from payload: RealtimeMessagePayload) {
        self.id = payload.id
        self.conversationId = payload.conversationId
        self.topic = payload.topic
        self.senderId = payload.from.id
        self.senderType = payload.from.type
        self.from = ChatPeer(type: payload.from.type, id: payload.from.id, name: payload.from.name, avatar: payload.from.avatar)
        self.to = ChatPeer(type: payload.to.type, id: payload.to.id, name: payload.to.name, avatar: payload.to.avatar)
        self.content = MessageContent(type: payload.content.type, body: payload.content.body, url: payload.content.url, name: payload.content.name, size: payload.content.size, meta: payload.content.meta)
        self.seq = payload.seq.map(Int.init)
        self.timestamp = payload.timestamp
        self.createdAt = Date(timeIntervalSince1970: Double(payload.timestamp))
    }
}

// MARK: - API Payloads

struct ApiResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T?
}

struct AuthTokens: Codable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct AuthPayload: Codable {
    let user: User
    let tokens: AuthTokens
}

struct UpdateProfileRequest: Codable {
    let nickname: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case nickname
        case avatarUrl = "avatar_url"
    }
}

struct ChangePasswordRequest: Codable {
    let oldPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case oldPassword = "old_password"
        case newPassword = "new_password"
    }
}
