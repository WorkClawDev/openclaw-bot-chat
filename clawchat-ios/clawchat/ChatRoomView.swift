import SwiftUI
import Combine
import MarkdownUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ChatContext {
    let id: String
    let title: String
    let subtitle: String
    let isGroup: Bool
    let groupId: String?
    let bot: Bot?
    let memberCount: Int?
    let avatarURLString: String?
    
    init(
        id: String,
        title: String,
        subtitle: String,
        isGroup: Bool,
        groupId: String? = nil,
        bot: Bot? = nil,
        memberCount: Int? = nil,
        avatarURLString: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isGroup = isGroup
        self.groupId = groupId
        self.bot = bot
        self.memberCount = memberCount
        self.avatarURLString = avatarURLString
    }
}

class ChatRoomViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var inputText = ""
    @Published var isLoading = false
    @Published var isLoadingOlder = false
    @Published var hasMoreHistory = true
    @Published var errorMessage: String?
    @Published var isUploadingImage = false
    @Published var connectionState: RealtimeConnectionState = .idle
    @Published private(set) var visibleWindowReplacementVersion = 0

    let conversationId: String

    private let pageSize = 50
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?
    private var botProfilesByID: [String: ChatPeerProfile] = [:]
#if DEBUG
    private static let isMessageTraceLoggingEnabled = false
#endif

    init(
        conversationId: String,
        initialMessages: [Message] = [],
        initialConnectionState: RealtimeConnectionState? = nil,
        observesRealtime: Bool = true
    ) {
        self.conversationId = conversationId
        self.messages = sortMessages(initialMessages)
        if let initialConnectionState {
            self.connectionState = initialConnectionState
        }

        if observesRealtime {
            RealtimeService.shared.$connectionState
                .receive(on: DispatchQueue.main)
                .assign(to: &$connectionState)

            RealtimeService.shared.messagePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    guard let self else { return }
                    guard Self.matchesConversation(message: message, conversationId: self.conversationId) else {
                        Self.logMessageTrace(
                            "MQTT TRACE ui ignored message_id=\(message.id) current_conversation=\(self.conversationId) message_conversation=\(message.conversationId) message_topic=\(message.topic)"
                        )
                        return
                    }

                    self.handleIncomingMessage(message)
                }
                .store(in: &cancellables)
        }

    }

    deinit {
        syncTask?.cancel()
    }

    func fetchMessages() {
        errorMessage = nil
        loadCachedBotProfiles()
        messages = sortMessages(enrichMessages(LocalMessageStore.shared.recentMessages(conversationId: conversationId, limit: pageSize)))
        updateHistoryAvailability()
        isLoading = messages.isEmpty

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.refreshLatestMessages()
        }
    }

    @MainActor
    func loadOlderMessages() async {
        guard !isLoadingOlder else { return }
        guard let beforeSequence = messages.first?.seq, beforeSequence > 1 else {
            hasMoreHistory = false
            return
        }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        let localOlderMessages = LocalMessageStore.shared.messagesBefore(
            conversationId: conversationId,
            beforeSequence: beforeSequence,
            limit: pageSize
        )
        if !localOlderMessages.isEmpty {
            messages = mergeMessages(messages, with: localOlderMessages)
        }

        guard localOlderMessages.count < pageSize else {
            updateHistoryAvailability()
            return
        }

        do {
            let remoteOlderMessages = try await fetchRemoteMessages(limit: pageSize, beforeSeq: beforeSequence)
            if !remoteOlderMessages.isEmpty {
                LocalMessageStore.shared.upsert(messages: remoteOlderMessages)
                messages = mergeMessages(messages, with: remoteOlderMessages)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        updateHistoryAvailability()
    }

    private func handleIncomingMessage(_ message: Message) {
        Self.logMessageTrace(
            "MQTT TRACE ui accepted message_id=\(message.id) conversation_id=\(message.conversationId) topic=\(message.topic) current_conversation=\(conversationId)"
        )
        messages = mergeMessages(messages, with: [enrichMessage(message)])
    }

    @MainActor
    private func refreshLatestMessages() async {
        defer { isLoading = false }

        do {
            var remoteMessages: [Message] = []
            if let lastSequence = LocalMessageStore.shared.highestSequence(conversationId: conversationId), lastSequence > 0 {
                let catchupMessages = try await fetchRemoteMessages(
                    limit: RealtimeService.shared.historyMaxCatchupBatch,
                    afterSeq: lastSequence
                )
                remoteMessages.append(contentsOf: catchupMessages)
            }

            let latestMessages = try await fetchRemoteMessages(limit: pageSize)
            remoteMessages.append(contentsOf: latestMessages)

            if !remoteMessages.isEmpty {
                LocalMessageStore.shared.upsert(messages: remoteMessages)
                if shouldReplaceVisibleWindow(withLatestPage: latestMessages) {
                    messages = sortMessages(latestMessages)
                    visibleWindowReplacementVersion += 1
                } else {
                    messages = mergeMessages(messages, with: remoteMessages)
                }
            }

            updateHistoryAvailability()
        } catch {
            updateHistoryAvailability()
            if messages.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fetchRemoteMessages(limit: Int, beforeSeq: Int? = nil, afterSeq: Int? = nil) async throws -> [Message] {
        let endpoint = messageEndpoint(limit: limit, beforeSeq: beforeSeq, afterSeq: afterSeq)

        return try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = APIClient.shared.request(endpoint)
                .receive(on: DispatchQueue.main)
                .sink { completion in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                    cancellable?.cancel()
                    cancellable = nil
                } receiveValue: { (messages: [Message]) in
                    continuation.resume(returning: self.sortMessages(self.enrichMessages(messages)))
                    cancellable?.cancel()
                    cancellable = nil
                }
        }
    }

    func seedBotProfile(_ bot: Bot?) {
        guard let bot else { return }
        applyBotProfiles([bot])
    }

    func refreshBotProfiles() {
        loadCachedBotProfiles()

        APIClient.shared.request("/api/v1/bots")
            .receive(on: DispatchQueue.main)
            .sink { _ in
            } receiveValue: { [weak self] (bots: [Bot]) in
                LocalMessageStore.shared.upsert(bots: bots)
                self?.applyBotProfiles(bots)
            }
            .store(in: &cancellables)
    }

    func refreshGroupBotProfiles(groupId: String?) {
        guard let groupId, !groupId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        APIClient.shared.request("/api/v1/groups/\(groupId)/members")
            .receive(on: DispatchQueue.main)
            .sink { _ in
            } receiveValue: { [weak self] (payload: GroupMembersPayload) in
                let bots = payload.bots.compactMap(\.bot)
                LocalMessageStore.shared.upsert(bots: bots)
                self?.applyBotProfiles(bots)
            }
            .store(in: &cancellables)
    }

    private func loadCachedBotProfiles() {
        applyBotProfiles(LocalMessageStore.shared.cachedBots())
    }

    private func applyBotProfiles(_ bots: [Bot]) {
        var changedProfiles = false
        prefetchBotAvatarImages(for: bots)

        for bot in bots {
            let id = Self.normalizedIdentifier(bot.id.uuidString)
            let avatar = firstNonEmpty(bot.avatarUrl, bot.avatar)
            let profile = ChatPeerProfile(name: bot.name, avatar: avatar)
            if botProfilesByID[id] != profile {
                botProfilesByID[id] = profile
                changedProfiles = true
            }
        }

        guard changedProfiles else { return }

        let enriched = enrichMessages(messages)
        if messagesNeedReplacement(messages, enriched) {
            messages = sortMessages(enriched)
        }
    }

    private func prefetchBotAvatarImages(for bots: [Bot]) {
        let urls = bots.compactMap { bot -> URL? in
            guard let avatar = firstNonEmpty(bot.avatarUrl, bot.avatar) else {
                return nil
            }
            return APIClient.shared.resolvedURL(from: avatar)
        }
        AvatarImagePrefetcher.prefetch(urls)
    }

    private func enrichMessages(_ items: [Message]) -> [Message] {
        items.map(enrichMessage)
    }

    private func enrichMessage(_ message: Message) -> Message {
        var updated = message
        updated.from = enrichPeer(updated.from)
        updated.to = enrichPeer(updated.to)
        return updated
    }

    private func enrichPeer(_ peer: ChatPeer) -> ChatPeer {
        guard Self.normalizedIdentifier(peer.type) == "bot",
              let profile = botProfilesByID[Self.normalizedIdentifier(peer.id)]
        else {
            return peer
        }

        var enriched = peer
        if let name = firstNonEmpty(profile.name) {
            enriched.name = name
        }
        if let avatar = firstNonEmpty(profile.avatar, peer.avatar) {
            enriched.avatar = avatar
        }
        return enriched
    }

    private func messagesNeedReplacement(_ lhs: [Message], _ rhs: [Message]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        return zip(lhs, rhs).contains { current, updated in
            current.from.name != updated.from.name
                || current.from.avatar != updated.from.avatar
                || current.to.name != updated.to.name
                || current.to.avatar != updated.to.avatar
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func messageEndpoint(limit: Int, beforeSeq: Int? = nil, afterSeq: Int? = nil) -> String {
        var endpoint = "/api/v1/messages/\(conversationId)?limit=\(max(1, min(limit, 200)))"
        if let beforeSeq {
            endpoint += "&before_seq=\(beforeSeq)"
        }
        if let afterSeq {
            endpoint += "&after_seq=\(afterSeq)"
        }
        return endpoint
    }

    private func mergeMessages(_ existing: [Message], with incoming: [Message]) -> [Message] {
        let merged = (existing + incoming).reduce(into: [String: Message]()) { result, message in
            result[message.id] = enrichMessage(message)
        }
        return sortMessages(Array(merged.values))
    }

    private func shouldReplaceVisibleWindow(withLatestPage latestMessages: [Message]) -> Bool {
        let latestPage = sortMessages(latestMessages)
        guard !latestPage.isEmpty else { return false }
        guard !messages.isEmpty else { return true }
        guard
            let currentLastSeq = messages.last?.seq,
            let latestFirstSeq = latestPage.first?.seq,
            let latestLastSeq = latestPage.last?.seq
        else {
            return false
        }

        let currentMessageIDs = Set(messages.map(\.id))
        let latestMessageIDs = Set(latestPage.map(\.id))
        if currentLastSeq >= latestLastSeq, !latestMessageIDs.isSubset(of: currentMessageIDs) {
            return true
        }

        return currentLastSeq + 1 < latestFirstSeq
    }

    private func sortMessages(_ items: [Message]) -> [Message] {
        items.sorted { lhs, rhs in
            let leftReplyTarget = replyTargetID(for: lhs)
            let rightReplyTarget = replyTargetID(for: rhs)
            if leftReplyTarget == rhs.id {
                return false
            }
            if rightReplyTarget == lhs.id {
                return true
            }

            let leftCreatedAt = lhs.createdAt?.timeIntervalSince1970 ?? 0
            let rightCreatedAt = rhs.createdAt?.timeIntervalSince1970 ?? 0
            if leftCreatedAt != rightCreatedAt {
                return leftCreatedAt < rightCreatedAt
            }

            let leftTimestamp = lhs.timestamp ?? 0
            let rightTimestamp = rhs.timestamp ?? 0
            if leftTimestamp != rightTimestamp {
                return leftTimestamp < rightTimestamp
            }

            if lhs.topic == rhs.topic,
               let leftSeq = lhs.seq,
               let rightSeq = rhs.seq,
               leftSeq != rightSeq {
                return leftSeq < rightSeq
            }

            return lhs.id < rhs.id
        }
    }

    private func replyTargetID(for message: Message) -> String? {
        let candidates = [
            message.content.meta?["replyToId"]?.stringValue,
            message.content.meta?["reply_to_id"]?.stringValue,
            message.content.meta?["replyToMessageId"]?.stringValue,
            message.content.meta?["reply_to_message_id"]?.stringValue,
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func matchesConversation(message: Message, conversationId: String) -> Bool {
        let expected = normalizedConversationReference(conversationId)
        return normalizedConversationReference(message.conversationId) == expected
            || normalizedConversationReference(message.topic) == expected
    }

    private static func normalizedConversationReference(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func logMessageTrace(_ message: String) {
#if DEBUG
        guard isMessageTraceLoggingEnabled else { return }
        print(message)
#endif
    }

    private func updateHistoryAvailability() {
        if let earliestSequence = messages.first?.seq {
            hasMoreHistory = earliestSequence > 1
        } else {
            hasMoreHistory = false
        }
    }

    func sendMessage(slashCommands: [SlashCommand] = []) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let outgoingContent = RealtimeContentPayload(
            type: "text",
            body: text,
            meta: slashCommandMeta(for: text, commands: slashCommands)
        )
        let didSend = RealtimeService.shared.sendMessage(
            conversationId: conversationId,
            content: outgoingContent,
            topic: conversationId
        )
        guard didSend else {
            errorMessage = "消息发送失败，请检查连接状态后重试。"
            return
        }

        inputText = ""
    }

    private func slashCommandMeta(for text: String, commands: [SlashCommand]) -> [String: AnyCodable]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }

        let commandName = trimmed
            .dropFirst()
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commandName, !commandName.isEmpty else {
            return nil
        }

        guard let matched = commands.first(where: { $0.name.caseInsensitiveCompare(commandName) == .orderedSame }) else {
            return nil
        }

        return [
            "command_source": AnyCodable("native"),
            "native_command": AnyCodable(true),
            "native_command_name": AnyCodable(matched.name),
        ]
    }

    @MainActor
    fileprivate func sendImage(item: PhotosPickerItem, mode: ImageSendMode) async {
        guard !isUploadingImage else { return }
        guard connectionState == .connected else {
            errorMessage = "当前连接不可用，暂时无法发送图片。"
            return
        }

        isUploadingImage = true
        defer { isUploadingImage = false }

        do {
            let preparedImage = try await normalizedUploadImage(from: item, mode: mode)
            let preparedUpload = try await APIClient.shared.prepareImageUpload(
                fileName: preparedImage.fileName,
                contentType: preparedImage.mimeType,
                size: preparedImage.data.count,
                conversationID: conversationId
            )

            try await APIClient.shared.uploadImageData(preparedImage.data, with: preparedUpload.upload)

            let assetID = preparedUpload.asset.id ?? ""
            let objectKey = preparedUpload.asset.objectKey ?? ""
            guard !assetID.isEmpty, !objectKey.isEmpty else {
                throw ChatImageError.invalidUploadResponse
            }

            let asset = try await APIClient.shared.completeImageUpload(assetID: assetID, objectKey: objectKey)
            _ = LocalImageStore.shared.cacheImageData(preparedImage.data, for: asset, fallbackIdentifier: preparedImage.fileName)
            let caption = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let outgoingContent = RealtimeContentPayload(
                type: "image",
                body: caption.isEmpty ? (asset.fileName ?? preparedImage.fileName) : caption,
                url: asset.preferredImageURLString,
                name: asset.fileName,
                size: asset.size,
                meta: ["asset": asset.metaValue]
            )

            let didSend = RealtimeService.shared.sendMessage(
                conversationId: conversationId,
                content: outgoingContent,
                topic: conversationId
            )
            guard didSend else {
                throw ChatImageError.messageSendFailed
            }

            inputText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedUploadImage(from item: PhotosPickerItem, mode: ImageSendMode) async throws -> UploadImagePayload {
        guard let rawData = try await item.loadTransferable(type: Data.self), !rawData.isEmpty else {
            throw ChatImageError.unreadableImage
        }

        let preferredType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
        let preferredMimeType = preferredType?.preferredMIMEType?.lowercased()

        if mode == .original,
           let preferredMimeType,
           Self.supportedImageMimeTypes.contains(preferredMimeType) {
            return originalUploadImagePayload(
                data: rawData,
                preferredType: preferredType,
                mimeType: preferredMimeType
            )
        }

        if mode == .compressed, preferredMimeType == "image/gif" {
            return originalUploadImagePayload(
                data: rawData,
                preferredType: preferredType,
                mimeType: "image/gif"
            )
        }

        guard let image = UIImage(data: rawData) else {
            throw ChatImageError.unsupportedImage
        }

        let jpegQuality = mode == .compressed ? Self.compressedJPEGQuality : Self.originalFallbackJPEGQuality
        let maxPixelSize = mode == .compressed ? Self.compressedMaxPixelSize : nil

        return try jpegUploadImagePayload(
            from: image,
            quality: jpegQuality,
            maxPixelSize: maxPixelSize
        )
    }

    private func originalUploadImagePayload(data: Data, preferredType: UTType?, mimeType: String) -> UploadImagePayload {
        let fileExtension = preferredType?.preferredFilenameExtension ?? fileExtension(for: mimeType)
        return UploadImagePayload(
            data: data,
            fileName: "image-\(UUID().uuidString.lowercased()).\(fileExtension)",
            mimeType: mimeType
        )
    }

    private func jpegUploadImagePayload(from image: UIImage, quality: CGFloat, maxPixelSize: CGFloat?) throws -> UploadImagePayload {
        let normalizedImage = normalizedJPEGSourceImage(from: image, maxPixelSize: maxPixelSize)
        let renderFormat = UIGraphicsImageRendererFormat.default()
        renderFormat.scale = 1

        let renderer = UIGraphicsImageRenderer(size: normalizedImage.size, format: renderFormat)
        let flattenedImage = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: normalizedImage.size))
            normalizedImage.draw(in: CGRect(origin: .zero, size: normalizedImage.size))
        }

        guard let jpegData = flattenedImage.jpegData(compressionQuality: quality) else {
            throw ChatImageError.unsupportedImage
        }

        return UploadImagePayload(
            data: jpegData,
            fileName: "image-\(UUID().uuidString.lowercased()).jpg",
            mimeType: "image/jpeg"
        )
    }

    private func normalizedJPEGSourceImage(from image: UIImage, maxPixelSize: CGFloat?) -> UIImage {
        guard let maxPixelSize else {
            return image
        }

        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > maxPixelSize, longestEdge > 0 else {
            return image
        }

        let scaleRatio = maxPixelSize / longestEdge
        let targetSize = CGSize(
            width: max(1, floor(image.size.width * scaleRatio)),
            height: max(1, floor(image.size.height * scaleRatio))
        )

        let renderFormat = UIGraphicsImageRendererFormat.default()
        renderFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: renderFormat)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func fileExtension(for mimeType: String) -> String {
        switch mimeType {
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        default:
            return "jpg"
        }
    }

    private static let supportedImageMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
    ]

    private static let compressedJPEGQuality: CGFloat = 0.72
    private static let originalFallbackJPEGQuality: CGFloat = 0.95
    private static let compressedMaxPixelSize: CGFloat = 2000
}

private struct ChatPeerProfile: Equatable {
    let name: String?
    let avatar: String?
}

private struct UploadImagePayload {
    let data: Data
    let fileName: String
    let mimeType: String
}

private enum ImageSendMode: CaseIterable, Hashable {
    case compressed
    case original

    var shortTitle: String {
        switch self {
        case .compressed:
            return "压缩"
        case .original:
            return "原图"
        }
    }

    var menuTitle: String {
        switch self {
        case .compressed:
            return "压缩发送（默认）"
        case .original:
            return "原图发送"
        }
    }

    var symbolName: String {
        switch self {
        case .compressed:
            return "arrow.down.circle"
        case .original:
            return "photo"
        }
    }
}

private struct PendingImageSelection: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
}

private struct SlashArgumentContext {
    let command: SlashCommand
    let arg: SlashCommandArg
    let argIndex: Int
    let partial: String
    let valueRange: Range<String.Index>
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private enum ChatImageError: LocalizedError {
    case unreadableImage
    case unsupportedImage
    case invalidUploadResponse
    case messageSendFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "无法读取所选图片，请换一张后重试。"
        case .unsupportedImage:
            return "当前图片格式暂不支持，且转换失败。"
        case .invalidUploadResponse:
            return "图片上传响应不完整，请稍后重试。"
        case .messageSendFailed:
            return "图片已上传，但消息发送失败，请重试。"
        }
    }
}

class GroupMaintenanceViewModel: ObservableObject {
    @Published var members: [GroupUserMember] = []
    @Published var botMembers: [GroupBotMember] = []
    @Published var allBots: [Bot] = []
    @Published var groupName = ""
    @Published var searchText = ""
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    func bootstrap(groupId: String, currentName: String) {
        groupName = currentName
        loadMembers(groupId: groupId)
        loadBots()
    }

    func loadMembers(groupId: String) {
        APIClient.shared.request("/api/v1/groups/\(groupId)/members")
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (payload: GroupMembersPayload) in
                self.members = payload.users
                self.botMembers = payload.bots
            }
            .store(in: &cancellables)
    }

    func loadBots() {
        APIClient.shared.request("/api/v1/bots")
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (bots: [Bot]) in
                self.allBots = bots
            }
            .store(in: &cancellables)
    }

    func renameGroup(groupId: String) {
        let payload: [String: String] = ["name": groupName]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        APIClient.shared.request("/api/v1/groups/\(groupId)", method: "PUT", body: body)
            .sink { _ in } receiveValue: { (_: ChatGroup) in }
            .store(in: &cancellables)
    }

    func removeMember(groupId: String, memberId: UUID) {
        APIClient.shared.request("/api/v1/groups/\(groupId)/members/\(memberId.uuidString)", method: "DELETE")
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: [String: String]) in
                self.loadMembers(groupId: groupId)
            }
            .store(in: &cancellables)
    }

    func addBot(groupId: String, botId: UUID) {
        let payload: [String: String] = ["bot_id": botId.uuidString]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        APIClient.shared.request("/api/v1/groups/\(groupId)/members", method: "POST", body: body)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: [String: String]) in
                self.loadMembers(groupId: groupId)
            }
            .store(in: &cancellables)
    }

    var filteredBots: [Bot] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { return allBots }
        return allBots.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }
}

struct ChatRoomView: View {
    let context: ChatContext
    @StateObject private var viewModel: ChatRoomViewModel
    @StateObject private var groupVM = GroupMaintenanceViewModel()
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var realtimeService = RealtimeService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showGroupSheet = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var previewMessage: Message?
    @State private var pendingImageSelection: PendingImageSelection?
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var isNearBottom = true
    @State private var hasPositionedInitialMessages = false
    @State private var isUserInteractingWithMessages = false
    @State private var selectedSlashCommandIndex = 0
    @State private var slashAutocompleteTask: Task<Void, Never>?
    private let loadsMessagesOnAppear: Bool
    private let currentUserIDOverride: String?
    private let bottomAnchorID = "chat-room-bottom-anchor"
    private let scrollCoordinateSpaceName = "chat-room-scroll-space"
    private let bottomAutoScrollThreshold: CGFloat = 96
    private let bottomMessageClearance: CGFloat = 24
    @FocusState private var isInputFocused: Bool

    init(context: ChatContext) {
        self.context = context
        self.loadsMessagesOnAppear = true
        self.currentUserIDOverride = nil
        _viewModel = StateObject(wrappedValue: ChatRoomViewModel(conversationId: context.id))
    }

    init(conversationId: String, title: String) {
        let context = ChatContext(id: conversationId, title: title, subtitle: "", isGroup: false, groupId: nil)
        self.init(context: context)
    }

    init(
        previewContext context: ChatContext,
        messages: [Message],
        connectionState: RealtimeConnectionState = .connected,
        currentUserID: String = "preview-user"
    ) {
        self.context = context
        self.loadsMessagesOnAppear = false
        self.currentUserIDOverride = currentUserID
        _viewModel = StateObject(wrappedValue: ChatRoomViewModel(
            conversationId: context.id,
            initialMessages: messages,
            initialConnectionState: connectionState,
            observesRealtime: false
        ))
    }

    var body: some View {
        ZStack {
            FrostedBackground()

            VStack(spacing: 0) {
                chatHeader

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleRow(
                                    message: message,
                                    currentUserID: effectiveCurrentUserID,
                                    showsSenderInfo: context.isGroup,
                                    fallbackBotAvatarURLString: context.isGroup ? nil : context.avatarURLString,
                                    onPreviewImage: { previewMessage = $0 }
                                )
                                    .id(message.id)
                            }

                            Color.clear
                                .frame(height: bottomMessageClearance)
                                .id(bottomAnchorID)
                                .background(
                                    ChatScrollBottomReader(
                                        coordinateSpaceName: scrollCoordinateSpaceName,
                                        onChange: handleScrollBottomChange
                                    )
                                )
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: scrollCoordinateSpaceName)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: ChatScrollViewportHeightPreferenceKey.self,
                                    value: geometry.size.height
                                )
                        }
                    )
                    .onPreferenceChange(ChatScrollViewportHeightPreferenceKey.self) { height in
                        guard shouldTrackScrollMetrics else { return }
                        guard abs(scrollViewportHeight - height) > 0.5 else { return }
                        scrollViewportHeight = height
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        inputBar
                    }
                    .onScrollPhaseChange { _, newPhase in
                        isUserInteractingWithMessages = newPhase.isScrolling
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        isInputFocused = false
                    }
                    .refreshable {
                        let anchorID = viewModel.messages.first?.id
                        await viewModel.loadOlderMessages()
                        await restoreVisiblePosition(anchorID, with: proxy)
                    }
                    .onAppear {
                        scheduleInitialMessagePositionIfNeeded(with: proxy)
                    }
                    .onChange(of: viewModel.visibleWindowReplacementVersion) { _, _ in
                        scheduleBottomPosition(with: proxy, revealMessages: true)
                    }
                    .onChange(of: viewModel.messages.last?.id) { oldID, newID in
                        guard shouldAutoScrollToBottom(oldLastID: oldID, newLastID: newID) else { return }
                        guard hasPositionedInitialMessages else {
                            scheduleInitialMessagePositionIfNeeded(with: proxy)
                            return
                        }
                        guard !isUserInteractingWithMessages || latestMessageWasSentByCurrentUser else {
                            return
                        }
                        guard isNearBottom || latestMessageWasSentByCurrentUser else {
                            return
                        }
                        scrollToBottom(with: proxy, animated: false)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                        scrollWithKeyboardTransition(notification, with: proxy)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            guard loadsMessagesOnAppear else { return }
            RealtimeService.shared.setActiveConversation(context.id)
            viewModel.seedBotProfile(context.bot)
            viewModel.refreshBotProfiles()
            viewModel.refreshGroupBotProfiles(groupId: context.groupId)
            viewModel.fetchMessages()
        }
        .onDisappear {
            guard loadsMessagesOnAppear else { return }
            slashAutocompleteTask?.cancel()
            RealtimeService.shared.setActiveConversation(nil)
        }
        .sheet(isPresented: $showGroupSheet) {
            if let groupId = context.groupId {
                GroupMaintenanceSheet(viewModel: groupVM, groupId: groupId)
                    .presentationDetents([.fraction(0.65)])
            }
        }
        .fullScreenCover(item: $pendingImageSelection) { selection in
            PendingImageSendScreen(
                selection: selection,
                isSending: viewModel.isUploadingImage,
                onCancel: {
                    pendingImageSelection = nil
                },
                onSend: { mode in
                    let item = selection.item
                    pendingImageSelection = nil
                    Task {
                        await viewModel.sendImage(item: item, mode: mode)
                    }
                }
            )
        }
        .fullScreenCover(item: $previewMessage) { message in
            ChatImagePreviewScreen(message: message)
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task(id: avatarPrefetchKey) {
            AvatarImagePrefetcher.prefetch(messageAvatarURLs)
        }
        .simultaneousGesture(edgeBackGesture)
    }

    private var chatHeader: some View {
        ChatChromeHeader(
            title: context.title,
            showSettings: context.isGroup || context.bot != nil,
            onBack: { dismiss() },
            settingsContent: {
                settingsAffordance
            }
        )
    }

    private var messageAvatarURLs: [URL] {
        let avatarStrings = viewModel.messages.compactMap { message -> String? in
            guard normalizeIdentifier(message.senderId) != normalizeIdentifier(effectiveCurrentUserID) else {
                return nil
            }

            if let avatar = message.from.avatar?.trimmingCharacters(in: .whitespacesAndNewlines), !avatar.isEmpty {
                return avatar
            }

            if !context.isGroup,
               normalizeIdentifier(message.from.type) == "bot",
               let fallback = context.avatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fallback.isEmpty {
                return fallback
            }

            return nil
        }

        var seen = Set<String>()
        return avatarStrings.compactMap { rawValue in
            guard let url = APIClient.shared.resolvedURL(from: rawValue) else {
                return nil
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else {
                return nil
            }
            return url
        }
    }

    private var avatarPrefetchKey: String {
        messageAvatarURLs
            .map(\.absoluteString)
            .sorted()
            .joined(separator: "|")
    }

    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onEnded { value in
                guard value.startLocation.x <= 28 else { return }
                guard value.translation.width > 72 else { return }
                guard value.translation.width > Swift.abs(value.translation.height) * 1.4 else { return }
                dismiss()
            }
    }

    @ViewBuilder
    private var settingsAffordance: some View {
        if context.isGroup {
            Button {
                showGroupSheet = true
                if let groupId = context.groupId {
                    groupVM.bootstrap(groupId: groupId, currentName: context.title)
                }
            } label: {
                ChatHeaderIcon(systemName: "gearshape.fill", accessibilityLabel: "群设置")
            }
            .buttonStyle(.plain)
        } else if let bot = context.bot {
            NavigationLink(destination: BotSettingsView(bot: bot, onBotUpdated: {
                // ChatRoomView doesn't manage the bot list, but the updated bot info
                // will be fetched when returning to BotsView.
            })) {
                ChatHeaderIcon(systemName: "gearshape.fill", accessibilityLabel: "机器人设置")
            }
            .buttonStyle(.plain)
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            slashCommandSuggestions

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: photoPickerSelection, matching: .images) {
                    ChatComposerIconButton(systemName: "plus", isUploading: false)
                }
                .disabled(viewModel.connectionState != .connected || viewModel.isUploadingImage)

                PhotosPicker(selection: photoPickerSelection, matching: .images) {
                    ChatComposerIconButton(systemName: "photo", isUploading: viewModel.isUploadingImage)
                }
                .disabled(viewModel.connectionState != .connected || viewModel.isUploadingImage)

                HStack(alignment: .bottom, spacing: 8) {
                    TextField(composerPlaceholder, text: $viewModel.inputText, axis: .vertical)
                        .focused($isInputFocused)
                        .lineLimit(1...5)
                        .textInputAutocapitalization(activeSlashQuery == nil ? .sentences : .never)
                        .autocorrectionDisabled(activeSlashQuery != nil)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color.rcmsTextPrimary)
                        .disabled(viewModel.connectionState != .connected || viewModel.isUploadingImage)
                        .onChange(of: slashSuggestionIdentity) { _, _ in
                            selectedSlashCommandIndex = 0
                            scheduleSlashAutocompleteIfNeeded()
                        }
                }
                .background(Color.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )

                Button(action: {
                    viewModel.sendMessage(slashCommands: realtimeService.slashCommands)
                }) {
                    ZStack {
                        Circle()
                            .fill(Color.rcmsAccent)
                            .frame(width: 44, height: 44)

                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: -1, y: 1)
                    }
                }
                .disabled(isSendDisabled)
                .opacity(isSendDisabled ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.white.opacity(0.78))
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var slashCommandSuggestions: some View {
        if let argContext = activeSlashArgumentContext, shouldShowSlashChoices {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredSlashChoices.isEmpty && isActiveSlashAutocompletePending {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 22, height: 22)

                            Text("Loading options")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.rcmsTextSecondary)

                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                    }

                    ForEach(Array(filteredSlashChoices.enumerated()), id: \.element.id) { index, choice in
                        Button {
                            insertSlashChoice(choice, context: argContext)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.rcmsAccent)
                                    .frame(width: 22, height: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.label)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.rcmsTextPrimary)
                                        .lineLimit(1)
                                    Text(choiceDetailText(choice, arg: argContext.arg))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color.rcmsTextSecondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 8)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(index == selectedSlashCommandIndex ? Color.rcmsAccent.opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)

                        if index < filteredSlashChoices.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
            }
            .frame(maxHeight: slashSuggestionPanelHeight(
                itemCount: filteredSlashChoices.count,
                isLoading: filteredSlashChoices.isEmpty && isActiveSlashAutocompletePending
            ))
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        } else if shouldShowSlashCommands {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSlashCommands.enumerated()), id: \.element.id) { index, command in
                        Button {
                            insertSlashCommand(command)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "command")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.rcmsAccent)
                                    .frame(width: 22, height: 22)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(command.name)")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color.rcmsTextPrimary)
                                        .lineLimit(1)
                                    if let description = command.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.rcmsTextSecondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer(minLength: 8)

                                if command.acceptsArgs {
                                    Image(systemName: "ellipsis.curlybraces")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.rcmsTextSecondary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(index == selectedSlashCommandIndex ? Color.rcmsAccent.opacity(0.08) : Color.clear)
                        }
                        .buttonStyle(.plain)

                        if index < filteredSlashCommands.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
            }
            .frame(maxHeight: slashSuggestionPanelHeight(itemCount: filteredSlashCommands.count))
            .background(Color.white.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        }
    }

    private func slashSuggestionPanelHeight(itemCount: Int, isLoading: Bool = false) -> CGFloat {
        let visibleRows = max(itemCount, isLoading ? 1 : 0)
        return min(CGFloat(max(visibleRows, 1)) * 50, 300)
    }

    private var composerPlaceholder: String {
        context.isGroup ? "Message group" : "Message \(context.title)"
    }

    private var activeSlashQuery: String? {
        guard let range = activeSlashTokenRange(in: viewModel.inputText) else {
            return nil
        }
        return String(viewModel.inputText[range].dropFirst())
    }

    private var filteredSlashCommands: [SlashCommand] {
        guard let query = activeSlashQuery else {
            return []
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return realtimeService.slashCommands
            .filter { command in
                normalizedQuery.isEmpty || command.name.lowercased().contains(normalizedQuery)
            }
    }

    private var activeSlashArgumentContext: SlashArgumentContext? {
        guard let lineRange = activeSlashLineRange(in: viewModel.inputText) else {
            return nil
        }

        let text = viewModel.inputText
        let afterSlash = text.index(after: lineRange.lowerBound)
        let commandNameEnd = text[afterSlash..<lineRange.upperBound]
            .firstIndex(where: { $0.isWhitespace })
            ?? lineRange.upperBound
        guard commandNameEnd < lineRange.upperBound else {
            return nil
        }

        let commandName = String(text[afterSlash..<commandNameEnd])
        guard let command = realtimeService.slashCommands.first(where: {
            $0.name.caseInsensitiveCompare(commandName) == .orderedSame
        }) else {
            return nil
        }

        let argsStart = text.index(after: commandNameEnd)
        let argsText = text[argsStart..<lineRange.upperBound]
        let endsWithWhitespace = text.index(before: lineRange.upperBound) >= argsStart
            ? text[text.index(before: lineRange.upperBound)].isWhitespace
            : true

        let valueRange: Range<String.Index>
        let partial: String
        let argIndex: Int
        if argsText.isEmpty || endsWithWhitespace {
            valueRange = lineRange.upperBound..<lineRange.upperBound
            partial = ""
            argIndex = argsText.split(whereSeparator: { $0.isWhitespace }).count
        } else {
            let valueStart = text[argsStart..<lineRange.upperBound]
                .lastIndex(where: { $0.isWhitespace })
                .map { text.index(after: $0) }
                ?? argsStart
            valueRange = valueStart..<lineRange.upperBound
            partial = String(text[valueRange])
            argIndex = text[argsStart..<valueStart]
                .split(whereSeparator: { $0.isWhitespace })
                .count
        }

        guard let arg = command.args?[safe: argIndex] else {
            return nil
        }

        return SlashArgumentContext(
            command: command,
            arg: arg,
            argIndex: argIndex,
            partial: partial,
            valueRange: valueRange
        )
    }

    private var filteredSlashChoices: [SlashCommandChoice] {
        guard let context = activeSlashArgumentContext else {
            return []
        }

        let normalizedQuery = context.partial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let staticChoices = context.arg.choices ?? []
        let dynamicChoices = activeSlashAutocompleteKey
            .flatMap { realtimeService.slashAutocompleteChoicesByKey[$0] }
            ?? []
        var seen = Set<String>()
        return (dynamicChoices + staticChoices)
            .filter { choice in
                guard !seen.contains(choice.value.lowercased()) else { return false }
                seen.insert(choice.value.lowercased())
                return normalizedQuery.isEmpty
                    || choice.label.lowercased().contains(normalizedQuery)
                    || choice.value.lowercased().contains(normalizedQuery)
            }
    }

    private var activeSlashAutocompleteKey: String? {
        guard let context = activeSlashArgumentContext else {
            return nil
        }
        return realtimeService.slashAutocompleteKey(
            commandName: context.command.name,
            argIndex: context.argIndex,
            partial: context.partial
        )
    }

    private var shouldShowSlashCommands: Bool {
        isInputFocused
            && activeSlashQuery != nil
            && !filteredSlashCommands.isEmpty
            && viewModel.connectionState == .connected
            && !viewModel.isUploadingImage
    }

    private var shouldShowSlashChoices: Bool {
        isInputFocused
            && activeSlashArgumentContext != nil
            && (!filteredSlashChoices.isEmpty || isActiveSlashAutocompletePending)
            && viewModel.connectionState == .connected
            && !viewModel.isUploadingImage
    }

    private var isActiveSlashAutocompletePending: Bool {
        activeSlashAutocompleteKey
            .map { realtimeService.slashAutocompletePendingKeys.contains($0) }
            ?? false
    }

    private var slashSuggestionIdentity: String {
        if let query = activeSlashQuery {
            return "command:\(query)"
        }
        if let context = activeSlashArgumentContext {
            return "choice:\(context.command.name):\(context.argIndex):\(context.partial)"
        }
        return "none"
    }

    private var isSendDisabled: Bool {
        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.connectionState != .connected
            || viewModel.isUploadingImage
    }

    private var effectiveCurrentUserID: String? {
        currentUserIDOverride ?? authManager.currentUser?.id.uuidString
    }

    private var photoPickerSelection: Binding<PhotosPickerItem?> {
        Binding(
            get: { selectedPhotoItem },
            set: { newValue in
                selectedPhotoItem = newValue
                guard let newValue else { return }
                pendingImageSelection = PendingImageSelection(item: newValue)
                selectedPhotoItem = nil
            }
        )
    }

    private func scheduleSlashAutocompleteIfNeeded() {
        slashAutocompleteTask?.cancel()
        guard let context = activeSlashArgumentContext,
              viewModel.connectionState == .connected,
              !viewModel.isUploadingImage
        else {
            return
        }

        let key = realtimeService.slashAutocompleteKey(
            commandName: context.command.name,
            argIndex: context.argIndex,
            partial: context.partial
        )
        guard realtimeService.slashAutocompleteChoicesByKey[key] == nil,
              !realtimeService.slashAutocompletePendingKeys.contains(key)
        else {
            return
        }

        slashAutocompleteTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            _ = realtimeService.requestSlashAutocomplete(
                commandName: context.command.name,
                argName: context.arg.name,
                argIndex: context.argIndex,
                partial: context.partial
            )
        }
    }

    private func insertSlashCommand(_ command: SlashCommand) {
        guard let range = activeSlashTokenRange(in: viewModel.inputText) else {
            return
        }

        viewModel.inputText.replaceSubrange(range, with: "/\(command.name) ")
        selectedSlashCommandIndex = 0
        isInputFocused = true
    }

    private func insertSlashChoice(_ choice: SlashCommandChoice, context: SlashArgumentContext) {
        viewModel.inputText.replaceSubrange(context.valueRange, with: "\(choice.value) ")
        selectedSlashCommandIndex = 0
        isInputFocused = true
    }

    private func choiceDetailText(_ choice: SlashCommandChoice, arg: SlashCommandArg) -> String {
        if let description = choice.description, !description.isEmpty {
            return description
        }
        if choice.value != choice.label {
            return choice.value
        }
        return arg.required ? "\(arg.name) required" : arg.name
    }

    private func activeSlashTokenRange(in text: String) -> Range<String.Index>? {
        guard let lineRange = activeSlashLineRange(in: text) else {
            return nil
        }

        let token = text[lineRange]
        guard token.first == "/" else {
            return nil
        }
        guard !token.dropFirst().contains(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        return lineRange
    }

    private func activeSlashLineRange(in text: String) -> Range<String.Index>? {
        guard !text.isEmpty else {
            return nil
        }

        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineRange = lineStart..<text.endIndex
        guard text[lineRange].first == "/" else {
            return nil
        }
        return lineRange
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool = true) {
        scrollToMessage(bottomAnchorID, with: proxy, anchor: .bottom, animated: animated)
    }

    private func scheduleInitialMessagePositionIfNeeded(with proxy: ScrollViewProxy) {
        guard !hasPositionedInitialMessages else { return }
        guard !viewModel.messages.isEmpty else { return }

        scheduleBottomPosition(with: proxy, revealMessages: true)
    }

    private func scheduleBottomPosition(with proxy: ScrollViewProxy, revealMessages: Bool = false) {
        guard !viewModel.messages.isEmpty else {
            if revealMessages {
                hasPositionedInitialMessages = true
            }
            return
        }

        Task { @MainActor in
            await Task.yield()
            scrollToBottom(with: proxy, animated: false)
            await Task.yield()
            scrollToBottom(with: proxy, animated: false)
            if revealMessages {
                hasPositionedInitialMessages = true
            }
        }
    }

    private func scrollWithKeyboardTransition(_ notification: Notification, with proxy: ScrollViewProxy) {
        guard isInputFocused else { return }
        guard !viewModel.messages.isEmpty else { return }
        guard keyboardOverlapsScreen(notification) else { return }

        withAnimation(keyboardAnimation(from: notification)) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
        hasPositionedInitialMessages = true
        isNearBottom = true
    }

    private func keyboardOverlapsScreen(_ notification: Notification) -> Bool {
        guard
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            return false
        }

        return endFrame.minY < UIScreen.main.bounds.maxY
    }

    private func keyboardAnimation(from notification: Notification) -> Animation {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let curveValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
        let curve = curveValue.flatMap(UIView.AnimationCurve.init(rawValue:))

        switch curve {
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .linear:
            return .linear(duration: duration)
        default:
            return .easeOut(duration: duration)
        }
    }

    private func shouldAutoScrollToBottom(oldLastID: String?, newLastID: String?) -> Bool {
        guard let newLastID else { return false }
        return oldLastID == nil || oldLastID != newLastID
    }

    private var latestMessageWasSentByCurrentUser: Bool {
        normalizeIdentifier(viewModel.messages.last?.senderId) == normalizeIdentifier(effectiveCurrentUserID)
    }

    private var shouldTrackScrollMetrics: Bool {
        !isInputFocused || isUserInteractingWithMessages
    }

    private func handleScrollBottomChange(_ bottomMaxY: CGFloat) {
        guard shouldTrackScrollMetrics else { return }
        updateBottomDistance(bottomMaxY)
    }

    private func normalizeIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    @MainActor
    private func restoreVisiblePosition(_ messageID: String?, with proxy: ScrollViewProxy) async {
        guard let messageID else { return }
        await Task.yield()
        scrollToMessage(messageID, with: proxy, anchor: .top, animated: false)
    }

    private func scrollToMessage(
        _ messageID: String,
        with proxy: ScrollViewProxy,
        anchor: UnitPoint,
        animated: Bool
    ) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(messageID, anchor: anchor)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(messageID, anchor: anchor)
            }
        }
    }

    private func updateBottomDistance(_ bottomMaxY: CGFloat) {
        guard scrollViewportHeight > 0 else { return }

        let nextIsNearBottom = (bottomMaxY - scrollViewportHeight) <= bottomAutoScrollThreshold
        if nextIsNearBottom != isNearBottom {
            isNearBottom = nextIsNearBottom
        }
    }
}

private struct ChatChromeHeader<SettingsContent: View>: View {
    let title: String
    let showSettings: Bool
    let onBack: () -> Void
    @ViewBuilder let settingsContent: () -> SettingsContent

    var body: some View {
        ZStack {
            HStack {
                Button(action: onBack) {
                    ChatHeaderIcon(systemName: "chevron.left", accessibilityLabel: "返回")
                }
                .buttonStyle(.plain)

                Spacer()

                if showSettings {
                    settingsContent()
                } else {
                    Color.clear
                        .frame(width: 36, height: 36)
                }
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.rcmsTextStrong)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 58)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.82))
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct ChatHeaderIcon: View {
    let systemName: String
    let accessibilityLabel: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.rcmsAccent)
            .frame(width: 36, height: 36)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct ChatComposerIconButton: View {
    let systemName: String
    let isUploading: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))

            if isUploading {
                ProgressView()
                    .tint(Color.rcmsAccent)
                    .frame(width: 44, height: 44)
            } else {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.rcmsAccent)
                    .frame(width: 44, height: 44)
            }
        }
        .accessibilityLabel(isUploading ? "Image uploading" : "Choose image")
    }
}

private struct ChatScrollBottomReader: View {
    let coordinateSpaceName: String
    let onChange: (CGFloat) -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let bottomMaxY = geometry.frame(in: .named(coordinateSpaceName)).maxY
            let pixelAlignedBottomMaxY = pixelAligned(bottomMaxY)

            Color.clear
                .task(id: pixelAlignedBottomMaxY) {
                    await Task.yield()
                    onChange(pixelAlignedBottomMaxY)
                }
        }
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (value * scale).rounded() / scale
    }
}

private struct ChatScrollViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct MessageMarkdownView: View {
    let text: String
    let isMe: Bool

    var body: some View {
        if shouldRenderMarkdown {
            Markdown(text)
                .markdownTheme(.rcmsChatTheme(isMe: isMe))
                .tint(isMe ? .white : .rcmsAccent)
        } else {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(isMe ? Color.white : Color.rcmsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var shouldRenderMarkdown: Bool {
        text.rangeOfCharacter(from: Self.markdownTriggerCharacters) != nil
    }

    private static let markdownTriggerCharacters = CharacterSet(charactersIn: "`*_#[]()>!\n")
}

extension Theme {
    static func rcmsChatTheme(isMe: Bool) -> Theme {
        Theme()
            .text {
                ForegroundColor(isMe ? .white : Color.rcmsTextPrimary)
                FontSize(15)
            }
            .code {
                FontFamily(ChatCodeTypography.markdownFontFamily)
                FontSize(14)
                BackgroundColor(isMe ? Color.white.opacity(0.15) : Color.gray.opacity(0.1))
            }
            .codeBlock { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    if let language = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                        Text(language.uppercased())
                            .font(ChatCodeTypography.labelFont())
                            .foregroundStyle(isMe ? Color.white.opacity(0.7) : Color.rcmsTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        ChatHighlightedCodeView(
                            code: configuration.content,
                            language: configuration.language,
                            isMe: isMe
                        )
                            .fixedSize(horizontal: true, vertical: false)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.top, configuration.language == nil ? 10 : 6)
                            .padding(.bottom, 10)
                    }
                }
                .background(isMe ? Color.black.opacity(0.2) : Color(red: 248/255, green: 250/255, blue: 252/255))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .markdownMargin(top: 8, bottom: 8)
            }
            .link {
                ForegroundColor(isMe ? .white : Color.rcmsAccent)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 0)
            }
    }
}

struct ChatBubbleRow: View {
    let message: Message
    let currentUserID: String?
    let showsSenderInfo: Bool
    let fallbackBotAvatarURLString: String?
    let onPreviewImage: ((Message) -> Void)?

    private var messageTimestamp: String? {
        guard let date = message.displayDate else {
            return nil
        }

        if Calendar.current.isDateInToday(date) {
            return ChatBubbleRow.timeFormatter.string(from: date)
        }

        return ChatBubbleRow.dateTimeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    private var isMe: Bool {
        normalizeIdentifier(message.senderId) == normalizeIdentifier(currentUserID)
    }

    private var isBot: Bool {
        normalizeIdentifier(message.from.type) == "bot"
    }

    private var isImageMessage: Bool {
        normalizeIdentifier(message.content.type) == "image"
    }

    private var imageName: String {
        let directName = message.content.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directName, !directName.isEmpty {
            return directName
        }

        let assetName = message.content.asset?.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assetName, !assetName.isEmpty {
            return assetName
        }

        return "图片"
    }

    private var imageCaption: String? {
        guard isImageMessage else { return nil }
        guard let body = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return nil
        }
        guard !message.content.isSticker else { return nil }
        guard normalizeIdentifier(body) != normalizeIdentifier(imageName) else { return nil }
        return body
    }

    private var senderIcon: String {
        isBot ? "cpu.fill" : "person.fill"
    }

    private var senderDisplayName: String {
        let rawName = message.from.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rawName.isEmpty {
            return rawName
        }
        return isBot ? "机器人" : "用户"
    }

    private var avatarFill: LinearGradient {
        if isBot {
            return LinearGradient(
                colors: [Color.rcmsAccent.opacity(0.95), Color(red: 56/255, green: 189/255, blue: 248/255)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [Color.white, Color(red: 226/255, green: 232/255, blue: 240/255)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe {
                Spacer(minLength: 44)
            } else {
                senderAvatar
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                if !isMe && showsSenderInfo {
                    HStack(spacing: 6) {
                        Text(senderDisplayName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.rcmsTextSecondary)

                        if isBot {
                            Text("BOT")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.rcmsAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.rcmsAccent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 4)
                }

                if isImageMessage {
                    imageMessageView
                } else if let body = message.content.body {
                    MessageMarkdownView(text: body, isMe: isMe)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(isMe ? Color.rcmsAccent : Color.white.opacity(0.95))
                        .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
                        .clipShape(BubbleShape(isMe: isMe))
                        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                }

                if let messageTimestamp {
                    Text(messageTimestamp)
                        .font(.caption2)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 300, alignment: isMe ? .trailing : .leading)

            if !isMe {
                Spacer(minLength: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
    }

    private var senderAvatar: some View {
        Group {
            if let avatar = senderAvatarURLString,
               let url = APIClient.shared.resolvedURL(from: avatar),
               !avatar.isEmpty {
                RemoteAvatarImage(url: url) {
                    senderAvatarFallback
                }
            } else {
                senderAvatarFallback
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
    }

    private var senderAvatarURLString: String? {
        if let avatar = message.from.avatar?.trimmingCharacters(in: .whitespacesAndNewlines), !avatar.isEmpty {
            return avatar
        }

        guard isBot,
              let fallback = fallbackBotAvatarURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fallback.isEmpty
        else {
            return nil
        }

        return fallback
    }

    private var senderAvatarFallback: some View {
        Circle()
            .fill(avatarFill)
            .overlay(
                Image(systemName: senderIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isBot ? .white : Color.rcmsTextSecondary)
            )
    }

    private func normalizeIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private var imageMessageView: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 8) {
            imageThumbnailView

            if let imageCaption {
                MessageMarkdownView(text: imageCaption, isMe: isMe)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(isMe ? Color.rcmsAccent : Color.white.opacity(0.95))
                    .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
                    .clipShape(BubbleShape(isMe: isMe))
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
            }
        }
    }
}

private extension ChatBubbleRow {
    @ViewBuilder
    var imageThumbnailView: some View {
        let thumbnail = CachedChatImageView(message: message)
            .frame(maxWidth: message.content.isSticker ? 160 : 280, maxHeight: message.content.isSticker ? 160 : 320)
            .clipShape(RoundedRectangle(cornerRadius: message.content.isSticker ? 18 : 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: message.content.isSticker ? 18 : 20, style: .continuous)
                    .stroke(Color.white.opacity(isMe ? 0.2 : 0.65), lineWidth: message.content.isSticker ? 0 : 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

        if let onPreviewImage {
            Button {
                onPreviewImage(message)
            } label: {
                thumbnail
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: message.content.isSticker ? 18 : 20, style: .continuous))
        } else {
            thumbnail
        }
    }
}

private struct CachedChatImageView: View {
    let message: Message

    @State private var cachedImage: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        Group {
            if let cachedImage {
                Image(uiImage: cachedImage)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .aspectRatio(displayAspectRatio, contentMode: .fit)
        .task(id: cacheTaskID) {
            await loadImageIfNeeded()
        }
    }

    private var cacheTaskID: String {
        message.content.asset?.id ?? message.content.imageURLString ?? message.id
    }

    @ViewBuilder
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.9))

            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)

                Text(placeholderLabel)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholderLabel: String {
        if didFail || message.content.imageURLString == nil {
            return "图片不可用"
        }
        return isLoading ? "图片加载中..." : "准备图片..."
    }

    private var displayAspectRatio: CGFloat {
        if let cachedImage {
            let width = cachedImage.size.width
            let height = cachedImage.size.height
            if width > 0, height > 0 {
                return width / height
            }
        }

        return message.content.isSticker ? 1 : (4 / 3)
    }

    @MainActor
    private func loadImageIfNeeded() async {
        if cachedImage != nil { return }

        if let cachedURL = LocalImageStore.shared.cachedFileURL(for: message),
           let cachedImage = await decodedImage(from: cachedURL) {
            self.cachedImage = cachedImage
            return
        }

        isLoading = true
        defer { isLoading = false }

        guard let cachedURL = await LocalImageStore.shared.ensureCachedImage(for: message),
              let cachedImage = await decodedImage(from: cachedURL)
        else {
            didFail = true
            return
        }

        self.cachedImage = cachedImage
        didFail = false
    }

    private func decodedImage(from fileURL: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: fileURL.path)
        }.value
    }
}

private struct PendingImageSendScreen: View {
    let selection: PendingImageSelection
    let isSending: Bool
    let onCancel: () -> Void
    let onSend: (ImageSendMode) -> Void

    @State private var previewImage: UIImage?
    @State private var originalSizeLabel: String?
    @State private var loadFailed = false
    @State private var sendMode: ImageSendMode = .compressed

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                Group {
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        previewPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)

                HStack(spacing: 14) {
                    Button {
                        sendMode = sendMode == .original ? .compressed : .original
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sendMode == .original ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .medium))
                            Text(originalOptionTitle)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        onSend(sendMode)
                    } label: {
                        HStack(spacing: 8) {
                            if isSending {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSending ? "发送中..." : "发送")
                                .font(.headline)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Color.rcmsAccent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || loadFailed)
                    .opacity((isSending || loadFailed) ? 0.7 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .background(Color.black.opacity(0.88))
            }
        }
        .task(id: selection.id) {
            await loadPreview()
        }
    }

    private var originalOptionTitle: String {
        if let originalSizeLabel {
            return "原图 \(originalSizeLabel)"
        }
        return "原图"
    }

    @ViewBuilder
    private var previewPlaceholder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay {
                VStack(spacing: 10) {
                    if loadFailed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text("图片预览加载失败")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        ProgressView()
                            .tint(.white)
                        Text("正在准备图片...")
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(24)
            }
            .padding(.horizontal, 12)
    }

    @MainActor
    private func loadPreview() async {
        guard previewImage == nil else { return }

        do {
            guard let rawData = try await selection.item.loadTransferable(type: Data.self), !rawData.isEmpty else {
                loadFailed = true
                return
            }

            originalSizeLabel = ByteCountFormatter.string(fromByteCount: Int64(rawData.count), countStyle: .file)

            if let image = UIImage(data: rawData) {
                previewImage = image
                loadFailed = false
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

private struct ChatImagePreviewScreen: View {
    let message: Message

    @Environment(\.dismiss) private var dismiss
    @State private var zoomScale: CGFloat = 1
    @State private var baseZoomScale: CGFloat = 1
    @State private var contentOffset: CGSize = .zero
    @State private var baseContentOffset: CGSize = .zero

    private var imageName: String {
        let directName = message.content.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let directName, !directName.isEmpty {
            return directName
        }

        let assetName = message.content.asset?.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let assetName, !assetName.isEmpty {
            return assetName
        }

        return "图片"
    }

    private var imageCaption: String? {
        guard let body = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            return nil
        }
        guard !message.content.isSticker else { return nil }
        guard body.lowercased() != imageName.lowercased() else { return nil }
        return body
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }

                    Spacer()

                    Text(imageName)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    Spacer()

                    Color.clear.frame(width: 28, height: 28)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                GeometryReader { proxy in
                    CachedChatImageView(message: message)
                        .frame(maxWidth: proxy.size.width, maxHeight: proxy.size.height)
                        .scaleEffect(zoomScale)
                        .offset(contentOffset)
                        .animation(.easeOut(duration: 0.2), value: zoomScale)
                        .animation(.easeOut(duration: 0.2), value: contentOffset)
                        .gesture(dragGesture.simultaneously(with: magnificationGesture))
                        .onTapGesture(count: 2) {
                            toggleZoom()
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let imageCaption {
                    Text(imageCaption)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                } else {
                    Spacer(minLength: 24)
                }
            }
        }
        .statusBarHidden()
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let nextScale = max(1, min(4, baseZoomScale * value))
                zoomScale = nextScale
                if nextScale <= 1.02 {
                    contentOffset = .zero
                }
            }
            .onEnded { _ in
                if zoomScale <= 1.02 {
                    resetZoom()
                } else {
                    baseZoomScale = zoomScale
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > 1 else { return }
                contentOffset = CGSize(
                    width: baseContentOffset.width + value.translation.width,
                    height: baseContentOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard zoomScale > 1 else {
                    resetZoom()
                    return
                }
                baseContentOffset = contentOffset
            }
    }

    private func toggleZoom() {
        if zoomScale > 1 {
            resetZoom()
        } else {
            zoomScale = 2
            baseZoomScale = 2
        }
    }

    private func resetZoom() {
        zoomScale = 1
        baseZoomScale = 1
        contentOffset = .zero
        baseContentOffset = .zero
    }
}


struct BubbleShape: Shape {
    let isMe: Bool

    func path(in rect: CGRect) -> Path {
        let tl: CGFloat = 16
        let tr: CGFloat = 16
        let bl: CGFloat = isMe ? 16 : 4
        let br: CGFloat = isMe ? 4 : 16

        var path = Path()
        path.move(to: CGPoint(x: tl, y: 0))
        path.addLine(to: CGPoint(x: rect.width - tr, y: 0))
        path.addArc(center: CGPoint(x: rect.width - tr, y: tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - br))
        path.addArc(center: CGPoint(x: rect.width - br, y: rect.height - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: bl, y: rect.height))
        path.addArc(center: CGPoint(x: bl, y: rect.height - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct GroupMaintenanceSheet: View {
    @ObservedObject var viewModel: GroupMaintenanceViewModel
    let groupId: String

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TextField("群名称", text: $viewModel.groupName)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button("保存群名称") {
                            viewModel.renameGroup(groupId: groupId)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.rcmsAccent)

                        Text("成员")
                            .font(.headline)

                        ForEach(viewModel.members) { member in
                            HStack {
                                Text(member.user?.username ?? member.nickname ?? member.userId.uuidString)
                                Spacer()
                                Button("移除") {
                                    viewModel.removeMember(groupId: groupId, memberId: member.userId)
                                }
                                .foregroundStyle(Color.rcmsDanger)
                            }
                        }

                        if !viewModel.botMembers.isEmpty {
                            Text("机器人成员")
                                .font(.headline)
                            ForEach(viewModel.botMembers) { member in
                                HStack {
                                    Text(member.bot?.name ?? member.nickname ?? member.botId.uuidString)
                                    Spacer()
                                    Text("已加入")
                                        .foregroundStyle(Color.rcmsTextSecondary)
                                        .font(.caption)
                                }
                            }
                        }

                        Text("+ 添加成员")
                            .font(.headline)

                        TextField("搜索机器人", text: $viewModel.searchText)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        ForEach(viewModel.filteredBots) { bot in
                            HStack {
                                Text(bot.name)
                                Spacer()
                                Button("添加") {
                                    viewModel.addBot(groupId: groupId, botId: bot.id)
                                }
                                .foregroundStyle(Color.rcmsAccent)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("群维护")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

#Preview("Bot Single Chat") {
    ChatRoomView(
        previewContext: ChatContext(
            id: "chat/dm/user/preview-user/bot/deploy-assistant",
            title: "Deploy Assistant",
            subtitle: "online",
            isGroup: false,
            bot: Bot(
                id: UUID(),
                ownerId: nil,
                name: "Deploy Assistant",
                description: "Release helper",
                avatar: nil,
                avatarUrl: nil,
                botType: nil,
                status: "online",
                mqttTopic: nil,
                createdAt: nil,
                updatedAt: nil
            )
        ),
        messages: ChatPreviewData.botMessages,
        connectionState: .connected
    )
    .preferredColorScheme(.light)
}

#Preview("Group Chat") {
    ChatRoomView(
        previewContext: ChatContext(
            id: "chat/group/openclaw-product",
            title: "OpenClaw Product Group",
            subtitle: "4 bots online",
            isGroup: true,
            groupId: "openclaw-product",
            memberCount: 18
        ),
        messages: ChatPreviewData.groupMessages,
        connectionState: .connected
    )
    .preferredColorScheme(.light)
}

private enum ChatPreviewData {
    static let botMessages: [Message] = [
        message(
            id: "bot-1",
            conversationID: "chat/dm/user/preview-user/bot/deploy-assistant",
            senderType: "bot",
            senderID: "deploy-assistant",
            senderName: "Deploy Assistant",
            body: "Build finished. Staging is healthy.",
            seq: 1,
            timestamp: 1_779_060_600
        ),
        message(
            id: "user-1",
            conversationID: "chat/dm/user/preview-user/bot/deploy-assistant",
            senderType: "user",
            senderID: "preview-user",
            senderName: "You",
            body: "Summarize the release risk.",
            seq: 2,
            timestamp: 1_779_060_660
        ),
        message(
            id: "bot-2",
            conversationID: "chat/dm/user/preview-user/bot/deploy-assistant",
            senderType: "bot",
            senderID: "deploy-assistant",
            senderName: "Deploy Assistant",
            body: "Here's the release risk summary:\n\n- Risk: low\n- Frontend: passed\n- Backend: passed",
            seq: 3,
            timestamp: 1_779_060_720
        )
    ]

    static let groupMessages: [Message] = [
        message(
            id: "group-1",
            conversationID: "chat/group/openclaw-product",
            senderType: "user",
            senderID: "mia",
            senderName: "Mia",
            body: "Image upload is ready for testing.",
            seq: 1,
            timestamp: 1_779_059_520
        ),
        message(
            id: "group-2",
            conversationID: "chat/group/openclaw-product",
            senderType: "bot",
            senderID: "ci-monitor",
            senderName: "CI Monitor",
            body: "Frontend build passed.\n\nBranch: feature/image-upload\nCommit: a1b2c3d\nDuration: 1m 24s\n\nAll checks passed",
            seq: 2,
            timestamp: 1_779_059_580
        ),
        message(
            id: "group-3",
            conversationID: "chat/group/openclaw-product",
            senderType: "user",
            senderID: "preview-user",
            senderName: "You",
            body: "Pin this summary for the team.",
            seq: 3,
            timestamp: 1_779_059_700
        )
    ]

    private static func message(
        id: String,
        conversationID: String,
        senderType: String,
        senderID: String,
        senderName: String,
        body: String,
        seq: Int,
        timestamp: Int64
    ) -> Message {
        Message(
            id: id,
            conversationId: conversationID,
            topic: conversationID,
            senderId: senderID,
            senderType: senderType,
            from: ChatPeer(type: senderType, id: senderID, name: senderName, avatar: nil),
            to: ChatPeer(type: "user", id: "preview-user", name: "You", avatar: nil),
            content: MessageContent(type: "text", body: body, url: nil, name: nil, size: nil, meta: nil),
            seq: seq,
            timestamp: timestamp,
            createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
    }
}

private extension Message {
    init(
        id: String,
        conversationId: String,
        topic: String,
        senderId: String,
        senderType: String,
        from: ChatPeer,
        to: ChatPeer,
        content: MessageContent,
        seq: Int?,
        timestamp: Int64?,
        createdAt: Date?
    ) {
        self.id = id
        self.conversationId = conversationId
        self.topic = topic
        self.senderId = senderId
        self.senderType = senderType
        self.from = from
        self.to = to
        self.content = content
        self.seq = seq
        self.timestamp = timestamp
        self.createdAt = createdAt
    }
}
