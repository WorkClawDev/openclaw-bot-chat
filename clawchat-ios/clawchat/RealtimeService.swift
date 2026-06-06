import Foundation
import Combine
import CocoaMQTT
import CocoaMQTTWebSocket

enum RealtimeConnectionState: Equatable {
    case idle, connecting, connected, disconnected
}

class RealtimeService: NSObject, ObservableObject {
    static let shared = RealtimeService()

    @Published var connectionState: RealtimeConnectionState = .idle
    @Published var lastMessagesByConversation: [String: Message] = [:]
    @Published var slashCommands: [SlashCommand] = []
    @Published var slashAutocompleteChoicesByKey: [String: [SlashCommandChoice]] = [:]
    @Published var slashAutocompletePendingKeys: Set<String> = []

    let messagePublisher = PassthroughSubject<Message, Never>()

    private var bootstrap: RealtimeBootstrapResponse?
    private var slashAutocompleteRequestIdsByKey: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var mqttClient: CocoaMQTT?
    private var activeConversationID: String?
    private var requestedTopics = Set<String>()
    private var subscribedTopics = Set<String>()
    private var retryWorkItem: DispatchWorkItem?
    private let retryDelay: TimeInterval = 3
#if DEBUG
    private static let isHighFrequencyLoggingEnabled = false
#endif

    var historyMaxCatchupBatch: Int {
        bootstrap?.history.maxCatchupBatch ?? 200
    }

    override init() {
        super.init()
    }

    func start() {
        guard AuthManager.shared.isAuthenticated else {
            log("start skipped: user is not authenticated")
            return
        }
        guard connectionState != .connected && connectionState != .connecting else {
            log("start skipped: current state=\(connectionState)")
            return
        }

        cancelRetry()
        connectionState = .connecting
        log("bootstrap request started")

        fetchBootstrap()
            .sink { [weak self] completion in
                if case .failure(let error) = completion {
                    self?.log("bootstrap failed: \(error)")
                    DispatchQueue.main.async {
                        self?.connectionState = .disconnected
                    }
                    self?.scheduleRetry(reason: "bootstrap_failed")
                }
            } receiveValue: { [weak self] bootstrap in
                self?.log(
                    "bootstrap ok client_id=\(bootstrap.clientId) broker_ws=\(bootstrap.broker.wsPublicURL) qos=\(bootstrap.broker.qos ?? -1) subscriptions=\(bootstrap.subscriptions.count) topics=\(self?.topicListDescription(bootstrap.subscriptions.map(\.topic)) ?? "[]")"
                )
                self?.bootstrap = bootstrap
                self?.connect(using: bootstrap)
            }
            .store(in: &cancellables)
    }

    func stop() {
        log("stop requested")
        cancelRetry()
        mqttClient?.disconnect()
        mqttClient = nil
        activeConversationID = nil
        requestedTopics.removeAll()
        subscribedTopics.removeAll()
        slashCommands.removeAll()
        slashAutocompleteChoicesByKey.removeAll()
        slashAutocompletePendingKeys.removeAll()
        slashAutocompleteRequestIdsByKey.removeAll()
        connectionState = .idle
    }

    func setActiveConversation(_ conversationID: String?) {
        activeConversationID = conversationID
        log("active conversation set to \(conversationID ?? "<nil>")")
        if let conversationID {
            ensureSubscribed(to: conversationID)
            LocalMessageStore.shared.markConversationRead(conversationId: conversationID)
        }
    }

    func ensureSubscribed(to topic: String, qos: Int? = nil) {
        let normalizedTopic = normalizedTopic(topic)
        guard !normalizedTopic.isEmpty else { return }

        let wasRequested = requestedTopics.contains(normalizedTopic)
        requestedTopics.insert(normalizedTopic)
        let alreadySubscribed = subscribedTopics.contains(normalizedTopic)

        guard connectionState == .connected,
              let mqttClient,
              !alreadySubscribed
        else {
            log(
                "subscribe deferred topic=\(normalizedTopic) was_requested=\(wasRequested) state=\(connectionState) has_client=\(mqttClient != nil) already_subscribed=\(alreadySubscribed)",
                highFrequency: alreadySubscribed
            )
            return
        }

        subscribe(topic: normalizedTopic, qos: qos ?? bootstrap?.broker.qos ?? 1, using: mqttClient)
    }

    private func fetchBootstrap() -> AnyPublisher<RealtimeBootstrapResponse, Error> {
        APIClient.shared.fetchRealtimeBootstrap()
    }

    private func connect(using bootstrap: RealtimeBootstrapResponse) {
        cancelRetry()
        guard let url = resolvedBrokerWebSocketURL(from: bootstrap.broker.wsPublicURL), let host = url.host else {
            log("connect failed: invalid broker ws_url=\(bootstrap.broker.wsPublicURL)")
            connectionState = .disconnected
            return
        }

        connectionState = .connecting

        mqttClient?.disconnect()
        mqttClient = nil
        subscribedTopics.removeAll()

        let secureSchemes = Set(["wss", "https"])
        let isSecure = secureSchemes.contains((url.scheme ?? "").lowercased())
        let defaultPort = isSecure ? 443 : 80
        let port = url.port ?? defaultPort

        let websocket = CocoaMQTTWebSocket(uri: url.path.isEmpty ? "/mqtt" : url.path)
        websocket.enableSSL = isSecure

        let mqtt = CocoaMQTT(clientID: bootstrap.clientId, host: host, port: UInt16(port), socket: websocket)
        mqtt.username = bootstrap.broker.username
        mqtt.password = bootstrap.broker.password
        mqtt.keepAlive = 60
        mqtt.autoReconnect = true
        mqtt.cleanSession = true
        mqtt.didReceiveTrust = { _, _, completionHandler in
            completionHandler(true)
        }
        mqtt.delegate = self

        mqttClient = mqtt
        log(
            "connect start url=\(url.absoluteString) host=\(host) port=\(port) path=\(url.path.isEmpty ? "/mqtt" : url.path) ssl=\(isSecure) client_id=\(bootstrap.clientId) username_set=\(bootstrap.broker.username != nil)"
        )
        _ = mqtt.connect()
    }

    private func resolvedBrokerWebSocketURL(from rawValue: String) -> URL? {
        guard let url = URL(string: rawValue) else {
            return APIClient.shared.brokerWebSocketFallbackURL
        }

        guard shouldFallbackFromBrokerURL(url) else {
            return url
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fallbackURL = APIClient.shared.brokerWebSocketFallbackURL,
              let fallbackComponents = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)
        else {
            return url
        }

        components.scheme = fallbackComponents.scheme
        components.host = fallbackComponents.host
        components.port = fallbackComponents.port
        if components.path.isEmpty || components.path == "/" {
            components.path = fallbackComponents.path
        }

        let resolved = components.url ?? fallbackURL
        log("broker ws_url \(rawValue) is loopback-only; fallback to \(resolved.absoluteString)")
        return resolved
    }

    private func shouldFallbackFromBrokerURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return true
        }

        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) {
            return true
        }

        return false
    }

    @discardableResult
    func sendMessage(conversationId: String, text: String, topic: String) -> Bool {
        sendMessage(
            conversationId: conversationId,
            content: RealtimeContentPayload(type: "text", body: text),
            topic: topic
        )
    }

    @discardableResult
    func sendMessage(conversationId: String, content: RealtimeContentPayload, topic: String) -> Bool {
        guard let mqttClient, let user = AuthManager.shared.currentUser else {
            log("publish blocked: has_client=\(mqttClient != nil) has_user=\(AuthManager.shared.currentUser != nil)")
            return false
        }

        ensureSubscribed(to: topic)

        let route = MessageRoute(topic: topic)
        guard let target = route.targetForSender(type: "user", id: user.id.uuidString.lowercased()) else {
            log("publish blocked: cannot resolve message target topic=\(topic)")
            return false
        }

        let normalizedBody = normalizedMessageBody(for: content)
        let outgoingContent = RealtimeContentPayload(
            type: content.type,
            body: normalizedBody,
            url: content.url,
            name: content.name,
            size: content.size,
            meta: content.meta
        )

        let payload = RealtimeMessagePayload(
            id: UUID().uuidString.lowercased(),
            topic: topic,
            conversationId: conversationId,
            timestamp: Int64(Date().timeIntervalSince1970),
            from: MessagePeerPayload(type: "user", id: user.id.uuidString.lowercased(), name: user.username),
            to: MessagePeerPayload(type: target.type, id: target.id, name: nil),
            content: outgoingContent,
            seq: nil
        )

        let optimisticMessage = Message(from: payload, pending: true)
        let isActiveConversation = normalizeConversationID(activeConversationID) == normalizeConversationID(conversationId)

        LocalMessageStore.shared.upsert(messages: [optimisticMessage])
        LocalMessageStore.shared.syncConversationPreview(
            for: optimisticMessage,
            currentUserID: user.id.uuidString,
            isActiveConversation: isActiveConversation
        )

        DispatchQueue.main.async {
            self.messagePublisher.send(optimisticMessage)
            self.lastMessagesByConversation[conversationId] = optimisticMessage
        }

        guard let jsonData = try? JSONEncoder().encode(payload) else {
            log("publish blocked: failed to encode payload id=\(payload.id) topic=\(topic)")
            return false
        }
        log(
            "publish topic=\(topic) conversation_id=\(conversationId) message_id=\(payload.id) to=\(target.type)/\(target.id) bytes=\(jsonData.count) subscribed=\(subscribedTopics.contains(topic))",
            highFrequency: true
        )
        mqttClient.publish(topic, withString: String(decoding: jsonData, as: UTF8.self), qos: .qos1)
        return true
    }

    @discardableResult
    func requestSlashAutocomplete(
        commandName: String,
        argName: String?,
        argIndex: Int,
        partial: String
    ) -> String? {
        guard let mqttClient, let user = AuthManager.shared.currentUser else {
            log("slash autocomplete skipped: has_client=\(mqttClient != nil) has_user=\(AuthManager.shared.currentUser != nil)")
            return nil
        }
        guard let requestTopic = normalizedOptionalTopic(bootstrap?.slashAutocompleteRequestTopic),
              let responseTopic = normalizedOptionalTopic(bootstrap?.slashAutocompleteResponseTopic)
        else {
            log("slash autocomplete skipped: topics unavailable")
            return nil
        }

        let normalizedCommandName = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommandName.isEmpty else {
            return nil
        }

        let normalizedPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = slashAutocompleteKey(
            commandName: normalizedCommandName,
            argIndex: argIndex,
            partial: normalizedPartial
        )
        let requestId = UUID().uuidString.lowercased()
        slashAutocompleteRequestIdsByKey[key] = requestId
        DispatchQueue.main.async {
            self.slashAutocompletePendingKeys.insert(key)
        }

        var meta: [String: AnyCodable] = [
            "content_type": AnyCodable("slash_autocomplete_request"),
            "request_id": AnyCodable(requestId),
            "response_topic": AnyCodable(responseTopic),
            "command_name": AnyCodable(normalizedCommandName),
            "arg_index": AnyCodable(argIndex),
            "partial": AnyCodable(normalizedPartial),
            "user_id": AnyCodable(user.id.uuidString.lowercased())
        ]
        if let argName, !argName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meta["arg_name"] = AnyCodable(argName.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let payload = RealtimeMessagePayload(
            id: requestId,
            topic: requestTopic,
            conversationId: requestTopic,
            timestamp: Int64(Date().timeIntervalSince1970),
            from: MessagePeerPayload(type: "user", id: user.id.uuidString.lowercased(), name: user.username),
            to: MessagePeerPayload(type: "system", id: "bot-chat", name: nil),
            content: RealtimeContentPayload(
                type: "control",
                body: "slash_autocomplete_request",
                meta: meta
            ),
            seq: nil
        )

        guard let jsonData = try? JSONEncoder().encode(payload) else {
            log("slash autocomplete skipped: failed to encode request id=\(requestId)")
            return nil
        }
        mqttClient.publish(requestTopic, withString: String(decoding: jsonData, as: UTF8.self), qos: .qos1)
        return key
    }

    func slashAutocompleteKey(commandName: String, argIndex: Int, partial: String) -> String {
        "\(commandName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(argIndex):\(partial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func handleRealtimePayload(_ payload: RealtimeMessagePayload) {
        if handleSlashAutocompleteResponseIfNeeded(payload) {
            return
        }
        if handleSlashCommandCatalogIfNeeded(payload) {
            return
        }

        log(
            "message decoded id=\(payload.id) topic=\(payload.topic) conversation_id=\(payload.conversationId) from=\(payload.from.type)/\(payload.from.id) to=\(payload.to.type)/\(payload.to.id) seq=\(payload.seq.map(String.init) ?? "<nil>")",
            highFrequency: true
        )
        let message = Message(from: payload)
        LocalMessageStore.shared.upsert(messages: [message])
        LocalMessageStore.shared.syncConversationPreview(
            for: message,
            currentUserID: AuthManager.shared.currentUser?.id.uuidString,
            isActiveConversation: normalizeConversationID(activeConversationID) == normalizeConversationID(message.conversationId)
        )
        DispatchQueue.main.async {
            self.messagePublisher.send(message)
            self.lastMessagesByConversation[message.conversationId] = message
        }
    }

    private func handleSlashCommandCatalogIfNeeded(_ payload: RealtimeMessagePayload) -> Bool {
        let contentType = payload.content.meta?["content_type"]?.stringValue
        let slashTopic = normalizedTopic(bootstrap?.slashCommandTopic)
        let payloadTopic = normalizedTopic(payload.topic)
        let isSlashCommandCatalog = contentType == "slash_commands" || (!slashTopic.isEmpty && payloadTopic == slashTopic)
        guard isSlashCommandCatalog else {
            return false
        }

        let commands = SlashCommand.catalog(from: payload.content.meta)
        log("slash commands catalog received topic=\(payload.topic) count=\(commands.count)")
        DispatchQueue.main.async {
            self.slashCommands = commands
        }
        return true
    }

    private func handleSlashAutocompleteResponseIfNeeded(_ payload: RealtimeMessagePayload) -> Bool {
        let contentType = payload.content.meta?["content_type"]?.stringValue
        let responseTopic = normalizedTopic(bootstrap?.slashAutocompleteResponseTopic)
        let payloadTopic = normalizedTopic(payload.topic)
        let isAutocompleteResponse = contentType == "slash_autocomplete_response"
            || (!responseTopic.isEmpty && payloadTopic == responseTopic)
        guard isAutocompleteResponse else {
            return false
        }

        guard let meta = payload.content.meta else {
            return true
        }

        let requestId = meta["request_id"]?.stringValue ?? meta["requestId"]?.stringValue
        let commandName = meta["command_name"]?.stringValue ?? meta["commandName"]?.stringValue ?? ""
        let argIndex = meta["arg_index"]?.intValue ?? meta["argIndex"]?.intValue ?? 0
        let partial = meta["partial"]?.stringValue ?? ""
        let key = slashAutocompleteKey(commandName: commandName, argIndex: argIndex, partial: partial)

        if let requestId, let expectedRequestId = slashAutocompleteRequestIdsByKey[key], expectedRequestId != requestId {
            return true
        }

        let choices = SlashCommandChoice.catalog(from: meta["choices"]?.arrayValue) ?? []
        log("slash autocomplete response received topic=\(payload.topic) key=\(key) choices=\(choices.count)")
        DispatchQueue.main.async {
            self.slashAutocompleteChoicesByKey[key] = choices
            self.slashAutocompletePendingKeys.remove(key)
        }
        return true
    }

    private func log(_ message: String, highFrequency: Bool = false) {
#if DEBUG
        guard !highFrequency || Self.isHighFrequencyLoggingEnabled else { return }
#else
        guard !highFrequency else { return }
#endif
        print("MQTT TRACE \(message)")
    }

    private func topicListDescription(_ topics: [String]) -> String {
        if topics.isEmpty {
            return "[]"
        }

        let preview = topics.prefix(8).joined(separator: ",")
        if topics.count <= 8 {
            return "[\(preview)]"
        }
        return "[\(preview),...+\(topics.count - 8)]"
    }

    private func normalizeConversationID(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func normalizedTopic(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedOptionalTopic(_ value: String?) -> String? {
        let normalized = normalizedTopic(value)
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedMessageBody(for content: RealtimeContentPayload) -> String {
        let trimmedBody = content.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBody, !trimmedBody.isEmpty {
            return trimmedBody
        }

        let trimmedName = content.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        switch normalizeConversationID(content.type) {
        case "image":
            return "Image"
        default:
            return ""
        }
    }


    private func scheduleRetry(reason: String) {
        guard AuthManager.shared.isAuthenticated else { return }
        guard connectionState != .connected && connectionState != .connecting else { return }
        guard retryWorkItem == nil else { return }

        log("retry scheduled reason=\(reason) delay=\(retryDelay)")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItem = nil
            self.log("retry triggered reason=\(reason)")
            self.start()
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }
}

extension RealtimeService: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else {
            log("connect rejected reason=\(ack.rawValue) description=\(ack)")
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
            scheduleRetry(reason: "connect_rejected")
            return
        }

        cancelRetry()
        log("connect accepted client_id=\(bootstrap?.clientId ?? "<unknown>")")
        DispatchQueue.main.async {
            self.connectionState = .connected
        }

        guard let bootstrap else { return }
        subscribedTopics.removeAll()
        log(
            "subscribing bootstrap_count=\(bootstrap.subscriptions.count) requested_count=\(requestedTopics.count) bootstrap_topics=\(topicListDescription(bootstrap.subscriptions.map(\.topic))) requested_topics=\(topicListDescription(Array(requestedTopics).sorted()))"
        )
        for sub in bootstrap.subscriptions {
            subscribe(topic: sub.topic, qos: sub.qos, using: mqtt)
        }
        for topic in requestedTopics {
            subscribe(topic: topic, qos: bootstrap.broker.qos ?? 1, using: mqtt)
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {
        log("state changed to \(state)")
        if state == .disconnected {
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
            scheduleRetry(reason: "state_disconnected")
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        log("receive raw topic=\(message.topic) packet_id=\(id) qos=\(message.qos.rawValue) bytes=\(message.payload.count)", highFrequency: true)
        guard let stringPayload = message.string else {
            log("receive dropped: payload is not utf8 topic=\(message.topic) bytes=\(message.payload.count)")
            return
        }

        guard let payloadData = stringPayload.data(using: .utf8) else {
            log("receive dropped: failed to convert payload string to data topic=\(message.topic)")
            return
        }

        do {
            let payload = try JSONDecoder().decode(RealtimeMessagePayload.self, from: payloadData)
            if normalizedTopic(payload.topic).isEmpty || normalizedTopic(payload.topic) != normalizedTopic(message.topic) {
                log("receive note: mqtt_topic=\(message.topic) payload_topic=\(payload.topic) conversation_id=\(payload.conversationId)")
            }

            handleRealtimePayload(payload)
        } catch {
            log("receive dropped: decode failed topic=\(message.topic) error=\(error)")
        }
    }

    private func subscribe(topic: String, qos: Int, using mqtt: CocoaMQTT) {
        let normalizedTopic = normalizedTopic(topic)
        guard !normalizedTopic.isEmpty, !subscribedTopics.contains(normalizedTopic) else {
            log("subscribe skipped topic=\(normalizedTopic) already_subscribed=\(subscribedTopics.contains(normalizedTopic))")
            return
        }

        log("subscribe request topic=\(normalizedTopic) qos=\(qos)")
        mqtt.subscribe(normalizedTopic, qos: CocoaMQTTQoS(rawValue: UInt8(qos)) ?? .qos1)
    }

    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        log("subscribe ack success=\(success.allKeys) failed=\(failed)")
        for key in success.allKeys {
            if let topic = key as? String {
                subscribedTopics.insert(topic)
            }
        }
        for topic in failed {
            subscribedTopics.remove(topic)
            log("subscribe failed topic=\(topic)")
        }
    }
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {
        log("unsubscribe ack topics=\(topics)")
    }
    func mqttDidPing(_ mqtt: CocoaMQTT) {
        log("ping sent", highFrequency: true)
    }
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        log("pong received", highFrequency: true)
    }
    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        if let err {
            log("disconnected error=\(err.localizedDescription)")
        } else {
            log("disconnected without error")
        }
        DispatchQueue.main.async {
            self.connectionState = .disconnected
        }
        scheduleRetry(reason: "socket_disconnected")
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        log("publish sent packet_id=\(id) topic=\(message.topic) qos=\(message.qos.rawValue) bytes=\(message.payload.count)", highFrequency: true)
    }
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        log("publish ack packet_id=\(id)", highFrequency: true)
    }
}

private struct MessageRoute {
    struct Peer {
        let type: String
        let id: String
    }

    let parts: [String]

    init(topic: String) {
        self.parts = topic.split(separator: "/").map(String.init)
    }

    func targetForSender(type: String, id: String) -> Peer? {
        if parts.count == 3, parts[0] == "chat", parts[1] == "group" {
            return Peer(type: "group", id: parts[2])
        }

        if parts.count == 6, parts[0] == "chat", parts[1] == "dm" {
            let left = Peer(type: parts[2], id: parts[3])
            let right = Peer(type: parts[4], id: parts[5])

            if left.type == type && left.id == id { return right }
            if right.type == type && right.id == id { return left }
        }

        return nil
    }
}
