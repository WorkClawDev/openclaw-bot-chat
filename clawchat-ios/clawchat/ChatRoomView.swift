import SwiftUI
import AVFoundation
import Combine
import MarkdownUI
import OSLog
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UIKit

#if DEBUG
private let chatScrollLogger = Logger(subsystem: "site.iotdevices.clawchat", category: "ChatScroll")

private func chatScrollDebug(_ message: String) {
    chatScrollLogger.debug("\(message, privacy: .public)")
}
#else
private func chatScrollDebug(_ message: String) {}
#endif

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

    private let initialPageSize = 50
    private let historyPageSize = 24
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
        messages = sortMessages(enrichMessages(LocalMessageStore.shared.recentMessages(conversationId: conversationId, limit: initialPageSize)))
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
            limit: historyPageSize
        )
        if !localOlderMessages.isEmpty {
            messages = mergeMessages(messages, with: localOlderMessages)
        }

        guard localOlderMessages.count < historyPageSize else {
            updateHistoryAvailability()
            return
        }

        do {
            let remoteOlderMessages = try await fetchRemoteMessages(limit: historyPageSize, beforeSeq: beforeSequence)
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

            let latestMessages = try await fetchRemoteMessages(limit: initialPageSize)
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
        let messages = try await APIClient.shared.fetchMessages(
            conversationID: conversationId,
            limit: limit,
            beforeSeq: beforeSeq,
            afterSeq: afterSeq
        )
        return sortMessages(enrichMessages(messages))
    }

    func seedBotProfile(_ bot: Bot?) {
        guard let bot else { return }
        applyBotProfiles([bot])
    }

    func refreshBotProfiles() {
        loadCachedBotProfiles()

        APIClient.shared.fetchBots()
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

        APIClient.shared.fetchGroupMembers(groupID: groupId)
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
            var imageMeta = ["asset": asset.metaValue]
            if let width = preparedImage.width {
                imageMeta["width"] = AnyCodable(width)
            }
            if let height = preparedImage.height {
                imageMeta["height"] = AnyCodable(height)
            }
            let outgoingContent = RealtimeContentPayload(
                type: "image",
                body: caption.isEmpty ? (asset.fileName ?? preparedImage.fileName) : caption,
                url: asset.preferredImageURLString,
                name: asset.fileName,
                size: asset.size,
                meta: imageMeta
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
        let imageSize = imagePixelSize(from: data)
        return UploadImagePayload(
            data: data,
            fileName: "image-\(UUID().uuidString.lowercased()).\(fileExtension)",
            mimeType: mimeType,
            width: imageSize?.width,
            height: imageSize?.height
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
            mimeType: "image/jpeg",
            width: Int(normalizedImage.size.width.rounded()),
            height: Int(normalizedImage.size.height.rounded())
        )
    }

    private func imagePixelSize(from data: Data) -> (width: Int, height: Int)? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        return (
            width: Int((image.size.width * image.scale).rounded()),
            height: Int((image.size.height * image.scale).rounded())
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
    let width: Int?
    let height: Int?
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
        APIClient.shared.fetchGroupMembers(groupID: groupId)
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
        APIClient.shared.fetchBots()
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
        APIClient.shared.updateGroupName(groupID: groupId, name: groupName)
            .sink { _ in } receiveValue: { (_: ChatGroup) in }
            .store(in: &cancellables)
    }

    func removeMember(groupId: String, memberId: UUID) {
        APIClient.shared.removeGroupMember(groupID: groupId, memberID: memberId)
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
        APIClient.shared.addBotToGroup(groupID: groupId, botID: botId)
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
    @State private var imageSaveStatus: ChatImageSaveStatus?
    @State private var isNearBottom = true
    @State private var hasPositionedInitialMessages = false
    @State private var isUserInteractingWithMessages = false
    @State private var isHistoryPreloadScheduled = false
    @State private var listScrollCommand = ChatListScrollCommand.none
    @State private var selectedSlashCommandIndex = 0
    @State private var slashAutocompleteTask: Task<Void, Never>?
    private let loadsMessagesOnAppear: Bool
    private let currentUserIDOverride: String?
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

                ChatMessageListView(
                    messages: viewModel.messages,
                    currentUserID: effectiveCurrentUserID,
                    showsSenderInfo: context.isGroup,
                    fallbackBotAvatarURLString: context.isGroup ? nil : context.avatarURLString,
                    isLoadingOlder: viewModel.isLoadingOlder,
                    hasMoreHistory: viewModel.hasMoreHistory,
                    bottomMessageClearance: bottomMessageClearance,
                    bottomAutoScrollThreshold: bottomAutoScrollThreshold,
                    scrollCommand: listScrollCommand,
                    onPreviewImage: { previewMessage = $0 },
                    onSaveImage: saveImage,
                    onLoadOlder: triggerHistoryPreloadIfNeeded,
                    onNearBottomChange: { isNearBottom = $0 },
                    onUserScrollChange: { isUserInteractingWithMessages = $0 },
                    onInitialPositioned: { hasPositionedInitialMessages = true }
                )
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    inputBar
                }
                .onTapGesture {
                    isInputFocused = false
                }
                .onAppear {
                    scheduleInitialMessagePositionIfNeeded()
                }
                .onChange(of: viewModel.visibleWindowReplacementVersion) { _, _ in
                    guard !isUserInteractingWithMessages else {
                        chatScrollDebug("visibleWindowReplacement skip: userInteracting=true")
                        return
                    }
                    guard !hasPositionedInitialMessages || isNearBottom || latestMessageWasSentByCurrentUser else {
                        chatScrollDebug("visibleWindowReplacement skip: positioned=true nearBottom=false latestMine=false")
                        return
                    }
                    chatScrollDebug("visibleWindowReplacement scheduleBottom positioned=\(hasPositionedInitialMessages) nearBottom=\(isNearBottom) latestMine=\(latestMessageWasSentByCurrentUser)")
                    scheduleBottomPosition(revealMessages: true)
                }
                .onChange(of: viewModel.messages.last?.id) { oldID, newID in
                    guard shouldAutoScrollToBottom(oldLastID: oldID, newLastID: newID) else { return }
                    guard hasPositionedInitialMessages else {
                        scheduleInitialMessagePositionIfNeeded()
                        return
                    }
                    guard !isUserInteractingWithMessages || latestMessageWasSentByCurrentUser else {
                        return
                    }
                    guard isNearBottom || latestMessageWasSentByCurrentUser else {
                        return
                    }
                    requestListScrollToBottom(animated: false)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    scrollWithKeyboardTransition(notification)
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
        .alert(item: $imageSaveStatus) { status in
            Alert(
                title: Text(status.title),
                message: Text(status.message),
                dismissButton: .default(Text("确定"))
            )
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
        ChatComposerBar(
            photoPickerSelection: photoPickerSelection,
            inputText: $viewModel.inputText,
            isInputFocused: $isInputFocused,
            placeholder: composerPlaceholder,
            isComposerDisabled: viewModel.connectionState != .connected || viewModel.isUploadingImage,
            isUploadingImage: viewModel.isUploadingImage,
            isSendDisabled: isSendDisabled,
            activeSlashQuery: activeSlashQuery,
            slashSuggestionIdentity: slashSuggestionIdentity,
            activeSlashArgumentContext: activeSlashArgumentContext,
            shouldShowSlashChoices: shouldShowSlashChoices,
            shouldShowSlashCommands: shouldShowSlashCommands,
            isActiveSlashAutocompletePending: isActiveSlashAutocompletePending,
            filteredSlashChoices: filteredSlashChoices,
            filteredSlashCommands: filteredSlashCommands,
            selectedSlashCommandIndex: selectedSlashCommandIndex,
            choiceDetailText: choiceDetailText,
            onSlashSuggestionIdentityChange: resetSlashSelectionAndAutocomplete,
            onSelectSlashChoice: insertSlashChoice,
            onSelectSlashCommand: insertSlashCommand,
            onSend: sendCurrentMessage
        )
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

    private func resetSlashSelectionAndAutocomplete() {
        selectedSlashCommandIndex = 0
        scheduleSlashAutocompleteIfNeeded()
    }

    private func sendCurrentMessage() {
        viewModel.sendMessage(slashCommands: realtimeService.slashCommands)
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

    @MainActor
    private func loadOlderMessagesPreservingPosition() async {
        guard !viewModel.isLoadingOlder else { return }
        await viewModel.loadOlderMessages()
    }

    private func triggerHistoryPreloadIfNeeded() {
        guard hasPositionedInitialMessages else { return }
        guard !viewModel.messages.isEmpty else { return }
        guard viewModel.hasMoreHistory else { return }
        guard !viewModel.isLoadingOlder else { return }
        guard !isHistoryPreloadScheduled else { return }

        chatScrollDebug("historyLoad request messageCount=\(viewModel.messages.count)")
        isHistoryPreloadScheduled = true
        Task { @MainActor in
            defer { isHistoryPreloadScheduled = false }
            await loadOlderMessagesPreservingPosition()
        }
    }

    private func scheduleInitialMessagePositionIfNeeded() {
        guard !hasPositionedInitialMessages else { return }
        guard !viewModel.messages.isEmpty else { return }

        scheduleBottomPosition(revealMessages: true)
    }

    private func scheduleBottomPosition(revealMessages: Bool = false) {
        guard !viewModel.messages.isEmpty else {
            if revealMessages {
                hasPositionedInitialMessages = true
            }
            return
        }

        chatScrollDebug("scheduleBottom queued reveal=\(revealMessages) positioned=\(hasPositionedInitialMessages) userInteracting=\(isUserInteractingWithMessages)")
        Task { @MainActor in
            await Task.yield()
            guard !isUserInteractingWithMessages || !hasPositionedInitialMessages else {
                chatScrollDebug("scheduleBottom cancelled after yield: userInteracting=true positioned=true")
                return
            }
            chatScrollDebug("scheduleBottom fire reveal=\(revealMessages) positioned=\(hasPositionedInitialMessages)")
            requestListScrollToBottom(animated: false)
        }
    }

    private func requestListScrollToBottom(animated: Bool) {
        chatScrollDebug("requestScrollToBottom animated=\(animated)")
        listScrollCommand = ChatListScrollCommand.scrollToBottom(animated: animated)
    }

    private func scrollWithKeyboardTransition(_ notification: Notification) {
        guard isInputFocused else { return }
        guard !viewModel.messages.isEmpty else { return }
        guard keyboardOverlapsScreen(notification) else { return }

        chatScrollDebug("keyboardTransition scrollToBottom")
        requestListScrollToBottom(animated: true)
        isNearBottom = true
    }

    private func keyboardOverlapsScreen(_ notification: Notification) -> Bool {
        guard
            let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else {
            return false
        }

        let screenMaxY = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.maxY }
            .max() ?? endFrame.maxY
        return endFrame.minY < screenMaxY
    }

    private func shouldAutoScrollToBottom(oldLastID: String?, newLastID: String?) -> Bool {
        guard let newLastID else { return false }
        return oldLastID == nil || oldLastID != newLastID
    }

    private var latestMessageWasSentByCurrentUser: Bool {
        normalizeIdentifier(viewModel.messages.last?.senderId) == normalizeIdentifier(effectiveCurrentUserID)
    }

    private func saveImage(_ message: Message) {
        Task { @MainActor in
            do {
                try await ChatImageSaver.save(message)
                imageSaveStatus = ChatImageSaveStatus(title: "已保存", message: "图片已保存到系统相册。")
            } catch {
                imageSaveStatus = ChatImageSaveStatus(
                    title: "保存失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func normalizeIdentifier(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }
}

private struct ChatListScrollCommand: Equatable {
    enum Kind: Equatable {
        case none
        case scrollToBottom(animated: Bool)
    }

    let id: UUID
    let kind: Kind

    static let none = ChatListScrollCommand(kind: .none)

    static func scrollToBottom(animated: Bool) -> ChatListScrollCommand {
        ChatListScrollCommand(kind: .scrollToBottom(animated: animated))
    }

    private init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }
}

private struct ChatMessageListView: UIViewRepresentable {
    let messages: [Message]
    let currentUserID: String?
    let showsSenderInfo: Bool
    let fallbackBotAvatarURLString: String?
    let isLoadingOlder: Bool
    let hasMoreHistory: Bool
    let bottomMessageClearance: CGFloat
    let bottomAutoScrollThreshold: CGFloat
    let scrollCommand: ChatListScrollCommand
    let onPreviewImage: (Message) -> Void
    let onSaveImage: (Message) -> Void
    let onLoadOlder: () -> Void
    let onNearBottomChange: (Bool) -> Void
    let onUserScrollChange: (Bool) -> Void
    let onInitialPositioned: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = ChatTableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.estimatedRowHeight = Coordinator.defaultEstimatedRowHeight
        tableView.rowHeight = UITableView.automaticDimension
        tableView.refreshControl = context.coordinator.makeRefreshControl()
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Coordinator.cellReuseIdentifier)
        context.coordinator.installChrome(on: tableView)
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.update(parent: self, tableView: tableView)
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        static let cellReuseIdentifier = "chat-message-cell"
        static let defaultEstimatedRowHeight: CGFloat = 120
        private static let minimumEstimatedRowHeight: CGFloat = 72
        private static let maximumEstimatedRowHeight: CGFloat = 220

        private struct PendingScrollToBottom {
            let animated: Bool
            let notifyInitialPosition: Bool
        }

        private struct PrependPositionSnapshot {
            let contentOffsetY: CGFloat
            let contentHeight: CGFloat
        }

        private struct MessageHeightCacheKey: Hashable {
            let signature: MessageRenderSignature
            let width: Int
        }

        private var parent: ChatMessageListView
        private var messages: [Message] = []
        private var lastScrollCommand = ChatListScrollCommand.none
        private var hasPositionedInitialMessages = false
        private var isNearBottom = true
        private var isRestoringPosition = false
        private var pendingInitialBottomPosition = false
        private var deferredNeedsReload = false
        private var pendingScrollToBottom: PendingScrollToBottom?
        private var footerHeight: CGFloat = 0
        private var measuredRowHeights: [MessageHeightCacheKey: CGFloat] = [:]
        private var estimatedUnmeasuredRowHeight: CGFloat = Coordinator.defaultEstimatedRowHeight
        private var lastObservedContentHeight: CGFloat?
        private var lastObservedContentOffsetY: CGFloat?
        private var lastObservedVisibleAnchor: VisibleMessageAnchor?
        private var isCompensatingContentHeightChange = false
        private var deferredChangedMessageIDs: Set<String> = []
        private var deferredMessagesAfterInteraction: [Message]?
        private var refreshControlSettleDeadline: TimeInterval?
        /// Keyed by `message.id`. Entries are evicted when the message's render
        /// signature changes so that `cachedRendered(for:)` recomputes stale blocks.
        private var renderedCache: [String: RenderedMessage] = [:]

        /// Set of message IDs for which a highlight `Task` has been submitted but
        /// not yet applied. Prevents duplicate Tasks for the same message.
        private var highlightInFlight: Set<String> = []
        private var highlightPalettesByMessageID: [String: CodeHighlightPalette] = [:]

        init(parent: ChatMessageListView) {
            self.parent = parent
        }

        private func logScroll(_ event: String, on tableView: UITableView? = nil, details: String = "") {
            #if DEBUG
            let state: String
            if let tableView {
                state = " offsetY=\(format(tableView.contentOffset.y)) contentH=\(format(tableView.contentSize.height)) boundsH=\(format(tableView.bounds.height)) dragging=\(tableView.isDragging) decel=\(tableView.isDecelerating) tracking=\(tableView.isTracking)"
            } else {
                state = ""
            }
            let suffix = details.isEmpty ? "" : " \(details)"
            chatScrollDebug("coord.\(event)\(state)\(suffix)")
            #endif
        }

        private func format(_ value: CGFloat) -> String {
            String(format: "%.1f", Double(value))
        }

        private func reconcileContentHeightChangeIfNeeded(on tableView: UITableView, event: String) {
            let currentHeight = tableView.contentSize.height
            let currentOffsetY = tableView.contentOffset.y
            guard currentHeight > 0 else { return }
            if isCompensatingContentHeightChange {
                lastObservedContentHeight = currentHeight
                lastObservedContentOffsetY = currentOffsetY
                lastObservedVisibleAnchor = visibleAnchor(in: tableView)
                return
            }
            let previousVisibleAnchor = lastObservedVisibleAnchor
            defer {
                lastObservedContentHeight = currentHeight
                lastObservedContentOffsetY = tableView.contentOffset.y
                lastObservedVisibleAnchor = visibleAnchor(in: tableView)
            }

            guard let previousHeight = lastObservedContentHeight,
                  let previousOffsetY = lastObservedContentOffsetY
            else { return }

            let heightDelta = currentHeight - previousHeight
            guard abs(heightDelta) >= 1 else { return }
            let offsetDelta = currentOffsetY - previousOffsetY
            logScroll(
                "contentHeight.changed",
                on: tableView,
                details: "event=\(event) delta=\(format(heightDelta)) previous=\(format(previousHeight)) offsetDelta=\(format(offsetDelta))"
            )

            if maintainBottomAfterContentHeightChangeIfNeeded(
                previousHeight: previousHeight,
                previousOffsetY: previousOffsetY,
                event: event,
                on: tableView
            ) {
                return
            }

            compensateContentHeightChangeIfNeeded(
                previousAnchor: previousVisibleAnchor,
                heightDelta: heightDelta,
                offsetDelta: offsetDelta,
                event: event,
                on: tableView
            )
        }

        private func maintainBottomAfterContentHeightChangeIfNeeded(
            previousHeight: CGFloat,
            previousOffsetY: CGFloat,
            event: String,
            on tableView: UITableView
        ) -> Bool {
            guard !isUserInteracting(with: tableView) else { return false }
            guard !isRestoringPosition else { return false }

            let previousVisibleBottom = previousOffsetY
                + tableView.bounds.height
                - tableView.adjustedContentInset.bottom
            let previousDistanceFromBottom = previousHeight - previousVisibleBottom
            let wasPinnedToBottom = pendingInitialBottomPosition
                || isNearBottom
                || previousDistanceFromBottom <= parent.bottomAutoScrollThreshold
            guard wasPinnedToBottom else { return false }

            let targetOffsetY = clampedOffsetY(
                tableView.contentSize.height
                    - tableView.bounds.height
                    + tableView.adjustedContentInset.bottom,
                in: tableView
            )
            guard abs(targetOffsetY - tableView.contentOffset.y) >= 0.5 else { return false }

            logScroll(
                "contentHeight.maintainBottom",
                on: tableView,
                details: "event=\(event) previousDistance=\(format(previousDistanceFromBottom)) targetY=\(format(targetOffsetY))"
            )
            isRestoringPosition = true
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: targetOffsetY),
                animated: false
            )
            DispatchQueue.main.async { [weak self] in
                self?.isRestoringPosition = false
            }
            return true
        }

        private func compensateContentHeightChangeIfNeeded(
            previousAnchor: VisibleMessageAnchor?,
            heightDelta: CGFloat,
            offsetDelta: CGFloat,
            event: String,
            on tableView: UITableView
        ) {
            if compensateContentHeightChangeUsingAnchorIfNeeded(
                previousAnchor: previousAnchor,
                heightDelta: heightDelta,
                offsetDelta: offsetDelta,
                event: event,
                on: tableView
            ) {
                return
            }

            guard shouldCompensateAutomaticOffsetChange(
                heightDelta: heightDelta,
                offsetDelta: offsetDelta,
                on: tableView
            ) else { return }

            let targetOffsetY = clampedOffsetY(tableView.contentOffset.y + heightDelta - offsetDelta, in: tableView)
            guard abs(targetOffsetY - tableView.contentOffset.y) >= 0.5 else { return }
            logScroll(
                "contentHeight.compensate",
                on: tableView,
                details: "event=\(event) heightDelta=\(format(heightDelta)) offsetDelta=\(format(offsetDelta)) targetY=\(format(targetOffsetY))"
            )
            isCompensatingContentHeightChange = true
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: targetOffsetY),
                animated: false
            )
            DispatchQueue.main.async { [weak self] in
                self?.isCompensatingContentHeightChange = false
            }
        }

        private func compensateContentHeightChangeUsingAnchorIfNeeded(
            previousAnchor: VisibleMessageAnchor?,
            heightDelta: CGFloat,
            offsetDelta: CGFloat,
            event: String,
            on tableView: UITableView
        ) -> Bool {
            guard isUserInteracting(with: tableView) else { return false }
            guard !isRestoringPosition else { return false }
            guard abs(heightDelta) >= 80 else { return false }
            guard let previousAnchor else { return false }
            guard let row = messages.firstIndex(where: { $0.id == previousAnchor.messageID }) else { return false }

            tableView.layoutIfNeeded()
            let indexPath = IndexPath(row: row, section: 0)
            let rect = tableView.rectForRow(at: indexPath)
            let targetOffsetY = targetOffsetY(for: previousAnchor, rowRect: rect, in: tableView)
            let correction = targetOffsetY - tableView.contentOffset.y
            guard abs(correction) >= 16 else { return false }
            guard abs(correction) <= abs(heightDelta) + 120 else { return false }

            logScroll(
                "contentHeight.anchorCompensate",
                on: tableView,
                details: "event=\(event) message=\(previousAnchor.messageID) heightDelta=\(format(heightDelta)) offsetDelta=\(format(offsetDelta)) correction=\(format(correction)) targetY=\(format(targetOffsetY))"
            )
            isCompensatingContentHeightChange = true
            tableView.setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: targetOffsetY),
                animated: false
            )
            DispatchQueue.main.async { [weak self] in
                self?.isCompensatingContentHeightChange = false
            }
            return true
        }

        private func shouldCompensateAutomaticOffsetChange(
            heightDelta: CGFloat,
            offsetDelta: CGFloat,
            on tableView: UITableView
        ) -> Bool {
            guard isUserInteracting(with: tableView) else { return false }
            guard !isRestoringPosition else { return false }
            guard abs(heightDelta) >= 24 else { return false }

            let missingHeightAdjustment = heightDelta - offsetDelta
            return abs(missingHeightAdjustment) >= 24
                && abs(missingHeightAdjustment) <= abs(heightDelta) + 80
        }

        func installChrome(on tableView: UITableView) {
            if let tableView = tableView as? ChatTableView {
                tableView.onDidMoveToWindow = { [weak self] tableView in
                    self?.tableViewDidEnterWindow(tableView)
                }
            }
            tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 8))
            updateFooter(on: tableView)
        }

        private func tableViewDidEnterWindow(_ tableView: UITableView) {
            guard isReadyForLayout(tableView) else { return }
            guard deferredNeedsReload || pendingScrollToBottom != nil else { return }
            if deferredNeedsReload {
                deferredNeedsReload = false
                logScroll("tableEnter.reloadData", on: tableView)
                tableView.reloadData()
            }
            drainPendingScrollIfReady(on: tableView)
            evaluateScrollState(on: tableView)
            // History messages that were loaded while the table wasn't visible
            // need highlights scheduled now that the window is ready.
            scheduleHighlights(in: tableView)
        }

        func update(parent: ChatMessageListView, tableView: UITableView) {
            self.parent = parent
            updateRefreshControl(on: tableView)
            updateFooter(on: tableView)

            let previousMessages = messages
            let previousIDs = previousMessages.map(\.id)
            let nextIDs = parent.messages.map(\.id)
            let previousSigs = renderSignatures(for: previousMessages)
            let nextSigs     = renderSignatures(for: parent.messages)
            let shouldReloadRows = previousSigs != nextSigs
            let wasNearBottom = isNearBottom
            let prependCount = prependedRowCount(previousIDs: previousIDs, nextIDs: nextIDs)
            let appendStart = appendedRowStart(previousIDs: previousIDs, nextIDs: nextIDs)
            let canLayout = isReadyForLayout(tableView)
            let userIsInteracting = canLayout && isUserInteracting(with: tableView)
            if canLayout, !userIsInteracting {
                layoutIfReady(tableView)
            }
            let previousVisibleAnchor = canLayout ? visibleAnchor(in: tableView) : nil
            let prependSnapshot = canLayout ? PrependPositionSnapshot(
                contentOffsetY: tableView.contentOffset.y,
                contentHeight: tableView.contentSize.height
            ) : nil

            if shouldDeferPrependedRows(prependCount: prependCount, on: tableView, canLayout: canLayout) {
                deferredMessagesAfterInteraction = parent.messages
                logScroll(
                    "update.prepend.deferred",
                    on: tableView,
                    details: "count=\(prependCount) refresh=\(isRefreshControlActive(on: tableView))"
                )
                evaluateScrollState(on: tableView)
                scheduleDeferredChangedRowsFlush(on: tableView)
                return
            }

            if canLayout,
               userIsInteracting,
               previousIDs == nextIDs,
               shouldReloadRows {
                let changedIDs = changedMessageIDs(
                    previousSigs: previousSigs,
                    nextSigs: nextSigs,
                    nextMessages: parent.messages
                )
                deferredMessagesAfterInteraction = parent.messages
                deferredChangedMessageIDs.formUnion(changedIDs)
                logScroll("update.reloadRows.deferred", on: tableView, details: "count=\(changedIDs.count)")
                evaluateScrollState(on: tableView)
                return
            }

            if !userIsInteracting {
                deferredMessagesAfterInteraction = nil
                deferredChangedMessageIDs.removeAll()
            }

            messages = parent.messages

            if !canLayout {
                deferredNeedsReload = true
                queueInitialBottomPositionIfNeeded()
                queueScrollCommandIfNeeded(parent.scrollCommand)
                return
            }

            // Schedule highlight pre-computation for any newly visible code blocks.
            // Must run after `messages` is updated and layout is ready so that
            // `cachedRendered(for:)` can populate the cache eagerly (req 4, 5, 6).
            scheduleHighlights(in: tableView)

            if previousMessages.isEmpty || previousIDs.isEmpty || nextIDs.isEmpty {
                logScroll("update.reloadData", on: tableView, details: "previous=\(previousMessages.count) next=\(nextIDs.count)")
                tableView.reloadData()
                layoutIfReady(tableView)
            } else if prependCount > 0 {
                logScroll("update.prepend", on: tableView, details: "count=\(prependCount)")
                insertPrependedRows(count: prependCount, preserving: prependSnapshot, in: tableView)
                evaluateScrollState(on: tableView)
                return
            } else if let appendStart {
                logScroll("update.append", on: tableView, details: "start=\(appendStart) count=\(nextIDs.count - appendStart) wasNearBottom=\(wasNearBottom)")
                insertAppendedRows(start: appendStart, count: nextIDs.count - appendStart, in: tableView)
                if wasNearBottom, !isUserInteracting(with: tableView) {
                    scrollToBottomAfterLayout(on: tableView, animated: false, notifyInitialPosition: false)
                }
            } else if shouldReloadRows {
                let anchor = previousVisibleAnchor
                logScroll("update.reloadRows", on: tableView, details: "wasNearBottom=\(wasNearBottom) anchor=\(anchor?.messageID ?? "nil")")
                UIView.performWithoutAnimation {
                    reloadChangedRows(previousSigs: previousSigs, nextSigs: nextSigs, in: tableView)
                    layoutIfReady(tableView)
                }
                if hasPositionedInitialMessages {
                    if wasNearBottom {
                        scrollToBottomAfterLayout(on: tableView, animated: false, notifyInitialPosition: false)
                    } else if let anchor {
                        restoreAfterLayout(anchor, in: tableView)
                    }
                }
            }

            if queueInitialBottomPositionIfNeeded() {
                drainPendingScrollIfReady(on: tableView)
                evaluateScrollState(on: tableView)
                return
            }

            if queueScrollCommandIfNeeded(parent.scrollCommand) {
                drainPendingScrollIfReady(on: tableView)
            }

            evaluateScrollState(on: tableView)
        }

        private func isReadyForLayout(_ tableView: UITableView) -> Bool {
            tableView.window != nil && tableView.bounds.width > 0 && tableView.bounds.height > 0
        }

        private func layoutIfReady(_ tableView: UITableView) {
            guard isReadyForLayout(tableView) else { return }
            tableView.layoutIfNeeded()
            reconcileContentHeightChangeIfNeeded(on: tableView, event: "layoutIfReady")
        }

        @discardableResult
        private func queueInitialBottomPositionIfNeeded() -> Bool {
            guard !hasPositionedInitialMessages, !messages.isEmpty, !pendingInitialBottomPosition else {
                return false
            }
            pendingInitialBottomPosition = true
            queueScrollToBottom(animated: false, notifyInitialPosition: true)
            return true
        }

        @discardableResult
        private func queueScrollCommandIfNeeded(_ command: ChatListScrollCommand) -> Bool {
            guard command != lastScrollCommand else { return false }
            lastScrollCommand = command
            switch command.kind {
            case .none:
                return false
            case .scrollToBottom(let animated):
                queueScrollToBottom(animated: animated, notifyInitialPosition: false)
                return true
            }
        }

        private func queueScrollToBottom(animated: Bool, notifyInitialPosition: Bool) {
            let shouldNotifyInitialPosition = notifyInitialPosition || (pendingScrollToBottom?.notifyInitialPosition == true)
            pendingScrollToBottom = PendingScrollToBottom(
                animated: animated,
                notifyInitialPosition: shouldNotifyInitialPosition
            )
        }

        private func drainPendingScrollIfReady(on tableView: UITableView) {
            guard isReadyForLayout(tableView), let pendingScrollToBottom else { return }
            self.pendingScrollToBottom = nil
            guard pendingScrollToBottom.notifyInitialPosition || !isUserInteracting(with: tableView) else {
                logScroll("drainPendingScroll.skipInteracting", on: tableView)
                return
            }
            logScroll("drainPendingScroll.fire", on: tableView, details: "animated=\(pendingScrollToBottom.animated) notifyInitial=\(pendingScrollToBottom.notifyInitialPosition)")
            scrollToBottomAfterLayout(
                on: tableView,
                animated: pendingScrollToBottom.animated,
                notifyInitialPosition: pendingScrollToBottom.notifyInitialPosition
            )
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            messages.count
        }

        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            UITableView.automaticDimension
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard messages.indices.contains(indexPath.row) else {
                return 0
            }

            let message = messages[indexPath.row]
            if let key = heightCacheKey(for: message, in: tableView),
               let cachedHeight = measuredRowHeights[key] {
                return cachedHeight
            }

            return estimatedUnmeasuredRowHeight
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard messages.indices.contains(indexPath.row) else { return }
            let displayedHeight = ceil(cell.bounds.height)
            guard displayedHeight > 1 else { return }
            guard let key = heightCacheKey(for: messages[indexPath.row], in: tableView) else { return }
            measuredRowHeights[key] = displayedHeight
            updateEstimatedUnmeasuredRowHeight()
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellReuseIdentifier, for: indexPath)
            guard messages.indices.contains(indexPath.row) else {
                cell.contentConfiguration = nil
                return cell
            }

            configureCell(cell, at: indexPath)
            return cell
        }

        private func configureCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
            guard messages.indices.contains(indexPath.row) else {
                cell.contentConfiguration = nil
                return
            }

            let message = messages[indexPath.row]
            let rendered = cachedRendered(for: message)
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.contentConfiguration = UIHostingConfiguration {
                ChatBubbleRow(
                    message: message,
                    rendered: rendered,
                    currentUserID: parent.currentUserID,
                    showsSenderInfo: parent.showsSenderInfo,
                    fallbackBotAvatarURLString: parent.fallbackBotAvatarURLString,
                    onPreviewImage: parent.onPreviewImage
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .margins(.all, 0)
        }

        func tableView(
            _ tableView: UITableView,
            contextMenuConfigurationForRowAt indexPath: IndexPath,
            point: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard messages.indices.contains(indexPath.row) else { return nil }
            let message = messages[indexPath.row]
            var actions: [UIMenuElement] = []

            if let text = message.content.body?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                actions.append(UIAction(title: "复制消息", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                })
            }

            if message.content.type.lowercased() == "image" {
                actions.append(UIAction(title: "保存图片", image: UIImage(systemName: "square.and.arrow.down")) { [parent] _ in
                    parent.onSaveImage(message)
                })
            }

            guard !actions.isEmpty else { return nil }
            return UIContextMenuConfiguration(identifier: message.id as NSString, previewProvider: nil) { _ in
                UIMenu(children: actions)
            }
        }

        private func heightCacheKey(for message: Message, in tableView: UITableView) -> MessageHeightCacheKey? {
            let width = tableView.bounds.width
            guard width > 0 else { return nil }
            let displayScale = max(tableView.traitCollection.displayScale, 1)
            return MessageHeightCacheKey(
                signature: MessageRenderSignature(message: message),
                width: Int((width * displayScale).rounded())
            )
        }

        private func updateEstimatedUnmeasuredRowHeight() {
            let samples = measuredRowHeights.values.sorted()
            guard !samples.isEmpty else {
                estimatedUnmeasuredRowHeight = Self.defaultEstimatedRowHeight
                return
            }
            let median = samples[samples.count / 2]
            estimatedUnmeasuredRowHeight = min(
                Self.maximumEstimatedRowHeight,
                max(Self.minimumEstimatedRowHeight, median)
            )
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let tableView = scrollView as? UITableView {
                reconcileContentHeightChangeIfNeeded(on: tableView, event: "didScroll")
            }
            guard !isRestoringPosition else { return }
            evaluateScrollState(on: scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            logScroll("drag.begin", on: scrollView as? UITableView)
            emit { [parent] in parent.onUserScrollChange(true) }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            logScroll("drag.end", on: scrollView as? UITableView, details: "decelerate=\(decelerate)")
            if !decelerate {
                if let tableView = scrollView as? UITableView {
                    scheduleDeferredChangedRowsFlush(on: tableView)
                }
                emit { [parent] in parent.onUserScrollChange(false) }
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            logScroll("decelerate.end", on: scrollView as? UITableView)
            if let tableView = scrollView as? UITableView {
                scheduleDeferredChangedRowsFlush(on: tableView)
            }
            emit { [parent] in parent.onUserScrollChange(false) }
        }

        func makeRefreshControl() -> UIRefreshControl {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(refreshControlPulled(_:)), for: .valueChanged)
            return refreshControl
        }

        @objc private func refreshControlPulled(_ refreshControl: UIRefreshControl) {
            guard parent.hasMoreHistory, !parent.isLoadingOlder else {
                logScroll("refresh.skip", details: "hasMore=\(parent.hasMoreHistory) loading=\(parent.isLoadingOlder)")
                refreshControl.endRefreshing()
                return
            }
            logScroll("refresh.loadOlder")
            parent.onLoadOlder()
        }

        private func updateRefreshControl(on tableView: UITableView) {
            guard let refreshControl = tableView.refreshControl else { return }
            refreshControl.isEnabled = parent.hasMoreHistory
            if !parent.isLoadingOlder, refreshControl.isRefreshing {
                refreshControlSettleDeadline = Date().timeIntervalSinceReferenceDate + 0.4
                logScroll("refresh.end", on: tableView)
                refreshControl.endRefreshing()
            }
        }

        private func updateFooter(on tableView: UITableView) {
            let nextFooterHeight = parent.bottomMessageClearance + 16
            guard abs(footerHeight - nextFooterHeight) > 0.5 else { return }
            footerHeight = nextFooterHeight
            tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: nextFooterHeight))
        }

        private func renderSignatures(for messages: [Message]) -> [MessageRenderSignature] {
            messages.map(MessageRenderSignature.init)
        }

        private func changedMessageIDs(
            previousSigs: [MessageRenderSignature],
            nextSigs: [MessageRenderSignature],
            nextMessages: [Message]
        ) -> Set<String> {
            guard previousSigs.count == nextSigs.count,
                  nextSigs.count == nextMessages.count
            else { return [] }

            var changedIDs: Set<String> = []
            for i in previousSigs.indices where previousSigs[i] != nextSigs[i] {
                changedIDs.insert(nextMessages[i].id)
            }
            return changedIDs
        }

        private func prependedRowCount(previousIDs: [String], nextIDs: [String]) -> Int {
            guard let previousFirstID = previousIDs.first,
                  let previousStart = nextIDs.firstIndex(of: previousFirstID),
                  previousStart > 0,
                  nextIDs.count == previousStart + previousIDs.count,
                  Array(nextIDs[previousStart...]) == previousIDs
            else {
                return 0
            }
            return previousStart
        }

        private func shouldDeferPrependedRows(
            prependCount: Int,
            on tableView: UITableView,
            canLayout: Bool
        ) -> Bool {
            guard canLayout, prependCount > 0 else { return false }
            return isUserInteracting(with: tableView) || isRefreshControlActive(on: tableView)
        }

        private func appendedRowStart(previousIDs: [String], nextIDs: [String]) -> Int? {
            guard nextIDs.count > previousIDs.count,
                  Array(nextIDs.prefix(previousIDs.count)) == previousIDs
            else {
                return nil
            }
            return previousIDs.count
        }

        private func insertPrependedRows(
            count: Int,
            preserving snapshot: PrependPositionSnapshot?,
            in tableView: UITableView
        ) {
            let indexPaths = (0..<count).map { IndexPath(row: $0, section: 0) }
            logScroll("insert.prepend.begin", on: tableView, details: "count=\(count) snapshotOffset=\(snapshot.map { format($0.contentOffsetY) } ?? "nil") snapshotHeight=\(snapshot.map { format($0.contentHeight) } ?? "nil")")
            UIView.performWithoutAnimation {
                tableView.performBatchUpdates {
                    tableView.insertRows(at: indexPaths, with: .none)
                } completion: { [weak self, weak tableView] _ in
                    guard let self, let tableView, let snapshot else { return }
                    self.logScroll("insert.prepend.completion", on: tableView)
                    self.restoreAfterPrepending(snapshot, in: tableView)
                }
                layoutIfReady(tableView)
                if let snapshot {
                    restorePrependOffset(snapshot, in: tableView)
                }
            }
        }

        private func insertAppendedRows(start: Int, count: Int, in tableView: UITableView) {
            guard count > 0 else { return }
            let indexPaths = (start..<(start + count)).map { IndexPath(row: $0, section: 0) }
            logScroll("insert.append.begin", on: tableView, details: "start=\(start) count=\(count)")
            UIView.performWithoutAnimation {
                tableView.performBatchUpdates {
                    tableView.insertRows(at: indexPaths, with: .none)
                }
                layoutIfReady(tableView)
            }
        }

        /// Reloads only the rows whose `MessageRenderSignature` changed between
        /// `previousSigs` and `nextSigs`. When counts differ (structural change),
        /// falls back to a full `reloadData()`.
        ///
        /// Evicts the render cache entries for each changed row so they are
        /// recomputed from the same source signature on the next layout pass.
        @discardableResult
        private func reloadChangedRows(
            previousSigs: [MessageRenderSignature],
            nextSigs: [MessageRenderSignature],
            in tableView: UITableView,
            reconfigureVisible: Bool = true
        ) -> Set<String> {
            guard previousSigs.count == nextSigs.count else {
                tableView.reloadData()
                return []
            }

            var changedPaths: [IndexPath] = []
            var changedIDs: Set<String> = []
            for i in previousSigs.indices {
                guard previousSigs[i] != nextSigs[i] else { continue }
                let msgID = messages[i].id
                changedIDs.insert(msgID)
                renderedCache.removeValue(forKey: msgID)
                highlightPalettesByMessageID.removeValue(forKey: msgID)
                changedPaths.append(IndexPath(row: i, section: 0))
            }

            guard !changedPaths.isEmpty else { return [] }
            measuredRowHeights = measuredRowHeights.filter { !changedIDs.contains($0.key.signature.id) }
            let visiblePaths = Set(tableView.indexPathsForVisibleRows ?? [])
            let visibleChangedPaths = changedPaths.filter { visiblePaths.contains($0) }
            logScroll(
                "reloadRows.suppressed",
                on: tableView,
                details: "count=\(changedPaths.count) visible=\(visibleChangedPaths.count)"
            )

            guard reconfigureVisible else { return changedIDs }
            for indexPath in visibleChangedPaths {
                guard let cell = tableView.cellForRow(at: indexPath) else { continue }
                configureCell(cell, at: indexPath)
            }
            return changedIDs
        }

        private func scheduleDeferredChangedRowsFlush(on tableView: UITableView, attempt: Int = 0) {
            let schedule: (@escaping () -> Void) -> Void = { work in
                if attempt == 0 {
                    DispatchQueue.main.async(execute: work)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                }
            }

            schedule { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                if (self.isUserInteracting(with: tableView) || self.isRefreshControlActive(on: tableView)),
                   attempt < 12 {
                    self.scheduleDeferredChangedRowsFlush(on: tableView, attempt: attempt + 1)
                    return
                }
                self.flushDeferredChangedRows(on: tableView)
            }
        }

        private func flushDeferredChangedRows(on tableView: UITableView) {
            guard !deferredChangedMessageIDs.isEmpty || deferredMessagesAfterInteraction != nil else { return }
            guard !isUserInteracting(with: tableView) else {
                logScroll("reloadRows.flush.skipInteracting", on: tableView, details: "count=\(deferredChangedMessageIDs.count)")
                return
            }
            guard !isRefreshControlActive(on: tableView) else {
                logScroll("reloadRows.flush.skipRefresh", on: tableView, details: "count=\(deferredChangedMessageIDs.count)")
                return
            }

            if let deferredMessages = deferredMessagesAfterInteraction {
                let anchor = visibleAnchor(in: tableView)
                let previousSigs = renderSignatures(for: messages)
                let nextSigs = renderSignatures(for: deferredMessages)
                deferredMessagesAfterInteraction = nil
                messages = deferredMessages

                let pendingIDs = deferredChangedMessageIDs
                deferredChangedMessageIDs.removeAll()
                let appliedIDs = reloadChangedRows(previousSigs: previousSigs, nextSigs: nextSigs, in: tableView)
                logScroll(
                    "reloadRows.flush",
                    on: tableView,
                    details: "count=\(pendingIDs.union(appliedIDs).count) visible=\((tableView.indexPathsForVisibleRows ?? []).count)"
                )
                layoutIfReady(tableView)
                if let anchor {
                    restoreAfterLayout(anchor, in: tableView)
                }
                return
            }

            let pendingIDs = deferredChangedMessageIDs
            deferredChangedMessageIDs.removeAll()
            let visiblePaths = tableView.indexPathsForVisibleRows ?? []
            let visibleChangedPaths = visiblePaths.filter { indexPath in
                messages.indices.contains(indexPath.row) && pendingIDs.contains(messages[indexPath.row].id)
            }

            logScroll("reloadRows.flush", on: tableView, details: "count=\(pendingIDs.count) visible=\(visibleChangedPaths.count)")
            for indexPath in visibleChangedPaths {
                guard let cell = tableView.cellForRow(at: indexPath) else { continue }
                configureCell(cell, at: indexPath)
            }
        }

        /// Returns a cached `RenderedMessage` for `message`, recomputing only when the
        /// pipeline signature changes (i.e., when `content.body`, `content.type`, or
        /// `content.url` differ from the cached version).
        private func cachedRendered(for message: Message) -> RenderedMessage {
            let sig = RenderedMessage.signature(for: message, currentUserID: parent.currentUserID)
            if let cached = renderedCache[message.id], cached.renderSignature == sig {
                return cached
            }
            let rendered = MessageRenderPipeline.render(message, currentUserID: parent.currentUserID)
            renderedCache[message.id] = rendered
            return rendered
        }

        // MARK: - Syntax Highlight Scheduling (req 4 – 7, 10 – 12)

        /// Schedules async highlight Tasks for every message in the current list that
        /// contains at least one un-highlighted `CodeBlock`.
        ///
        /// Rules enforced here:
        /// - Only one Task per message at a time (`highlightInFlight` guard, req 10).
        /// - `cachedRendered(for:)` is called to pre-populate the cache so history
        ///   messages are ready before the first `cellForRowAt` (req 5).
        /// - `scheduleHighlights` itself is synchronous; the async work happens inside
        ///   the Task and is merged into `renderedCache` on the main actor.
        /// - prepend / append / scroll / restore logic is not touched (req 15).
        private func scheduleHighlights(in tableView: UITableView) {
            let isDark = tableView.traitCollection.userInterfaceStyle == .dark
            let currentUserID = parent.currentUserID

            for message in messages {
                // Quick heuristic: only text-type messages with code fences need processing.
                let msgType = message.content.type.lowercased()
                guard msgType != "image", msgType != "audio", msgType != "voice" else { continue }
                guard message.content.body?.contains("```") == true else { continue }

                let jobKey = message.id
                guard !highlightInFlight.contains(jobKey) else { continue }

                // Eagerly populate renderedCache so cell rendering finds a cache hit.
                let rendered = cachedRendered(for: message)
                let isMe = rendered.isMe
                let palette: CodeHighlightPalette = isMe ? .sent
                    : (isDark ? .receivedDark : .receivedLight)
                let cachedPalette = highlightPalettesByMessageID[jobKey]
                let needsPaletteRefresh = cachedPalette != nil && cachedPalette != palette

                // Collect code blocks that still need highlights.
                let pending = rendered.blocks.compactMap { block -> CodeBlock? in
                    guard case .code(let cb) = block, !cb.source.isEmpty else { return nil }
                    return (needsPaletteRefresh || rendered.codeHighlights[cb.id] == nil) ? cb : nil
                }
                guard !pending.isEmpty else { continue }

                highlightInFlight.insert(jobKey)

                // Task captures message by value (Sendable). All async work runs
                // off-main via CodeHighlightService actor; the result is merged into
                // cache on the main actor without reloading table rows.
                Task { [weak self] in
                    // renderWithHighlights calls CodeHighlightService actor internally.
                    // No UIKit / SwiftUI interaction here.
                    let withHighlights = await MessageRenderPipeline.renderWithHighlights(
                        message,
                        currentUserID: currentUserID,
                        palette: palette
                    )

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.applyHighlights(from: withHighlights, palette: palette)
                    }
                }
            }
        }

        /// Merges newly computed `codeHighlights` into the cached `RenderedMessage` and
        /// does not touch the table view.
        ///
        /// Requirements specifically enforced here:
        /// - req 10: only the target message's `RenderedMessage` is updated.
        /// - req 11/12: no row reload is triggered by async highlight completion.
        ///   With self-sizing table rows, even a no-op reload can perturb offset while
        ///   the user is scrolling.
        private func applyHighlights(
            from withHighlights: RenderedMessage,
            palette: CodeHighlightPalette
        ) {
            let messageID = withHighlights.messageID
            highlightInFlight.remove(messageID)

            guard !withHighlights.codeHighlights.isEmpty else { return }

            // Merge into the existing cache entry if the message content hasn't changed.
            if var existing = renderedCache[messageID],
               existing.renderSignature == withHighlights.renderSignature {
                for (blockID, text) in withHighlights.codeHighlights {
                    existing.codeHighlights[blockID] = text
                }
                renderedCache[messageID] = existing
                highlightPalettesByMessageID[messageID] = palette
                logScroll("highlight.cacheMerge", details: "message=\(messageID) blocks=\(withHighlights.codeHighlights.count)")
            } else if renderedCache[messageID] == nil {
                // Cache was evicted (e.g., by reloadChangedRows) but the message is
                // still present; restore with highlights so the next cellForRowAt is fast.
                renderedCache[messageID] = withHighlights
                highlightPalettesByMessageID[messageID] = palette
                logScroll("highlight.cacheRestore", details: "message=\(messageID) blocks=\(withHighlights.codeHighlights.count)")
            } else {
                // renderSignature changed → the message content was edited while the
                // Task was in flight; the normal reloadChangedRows path handles this.
                return
            }
        }

        private func visibleAnchor(in tableView: UITableView) -> VisibleMessageAnchor? {
            guard isReadyForLayout(tableView) else { return nil }
            let visibleTop = tableView.contentOffset.y + tableView.adjustedContentInset.top
            let visibleHeight = visibleHeight(in: tableView)
            let referenceFraction: CGFloat = 0.45
            let referenceY = visibleTop + visibleHeight * referenceFraction
            let visibleBottom = visibleTop + visibleHeight
            let candidates = (tableView.indexPathsForVisibleRows ?? [])
                .sorted()
                .compactMap { indexPath -> (indexPath: IndexPath, rect: CGRect, score: CGFloat)? in
                    guard messages.indices.contains(indexPath.row) else { return nil }
                    let rect = tableView.rectForRow(at: indexPath)
                    guard rect.maxY > visibleTop + 1, rect.minY < visibleBottom - 1 else { return nil }
                    let score: CGFloat
                    if rect.minY <= referenceY, rect.maxY >= referenceY {
                        score = 0
                    } else {
                        score = min(abs(rect.minY - referenceY), abs(rect.maxY - referenceY))
                    }
                    return (indexPath, rect, score)
                }
            guard let best = candidates.min(by: { left, right in
                if left.score == right.score {
                    return left.indexPath.row < right.indexPath.row
                }
                return left.score < right.score
            }) else {
                return nil
            }
            return VisibleMessageAnchor(
                messageID: messages[best.indexPath.row].id,
                offsetFromReferenceY: best.rect.minY - referenceY,
                referenceFraction: referenceFraction
            )
        }

        private func visibleHeight(in tableView: UITableView) -> CGFloat {
            max(
                1,
                tableView.bounds.height
                    - tableView.adjustedContentInset.top
                    - tableView.adjustedContentInset.bottom
            )
        }

        private func targetOffsetY(
            for anchor: VisibleMessageAnchor,
            rowRect rect: CGRect,
            in tableView: UITableView
        ) -> CGFloat {
            let referenceOffset = visibleHeight(in: tableView) * anchor.referenceFraction
            return clampedOffsetY(
                rect.minY
                    - anchor.offsetFromReferenceY
                    - tableView.adjustedContentInset.top
                    - referenceOffset,
                in: tableView
            )
        }

        private func restoreAfterLayout(_ anchor: VisibleMessageAnchor, in tableView: UITableView) {
            guard !isUserInteracting(with: tableView) else {
                logScroll("restoreAnchor.skipInteracting", on: tableView, details: "message=\(anchor.messageID)")
                return
            }
            logScroll("restoreAnchor.begin", on: tableView, details: "message=\(anchor.messageID)")
            restore(anchor, in: tableView)
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                guard !self.isUserInteracting(with: tableView) else {
                    self.logScroll("restoreAnchor.secondPass.skipInteracting", on: tableView, details: "message=\(anchor.messageID)")
                    return
                }
                self.logScroll("restoreAnchor.secondPass", on: tableView, details: "message=\(anchor.messageID)")
                self.restore(anchor, in: tableView)
            }
        }

        private func restoreAfterPrepending(_ snapshot: PrependPositionSnapshot, in tableView: UITableView) {
            restorePrependOffset(snapshot, in: tableView)
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                self.restorePrependOffset(snapshot, in: tableView)
            }
        }

        private func isUserInteracting(with tableView: UITableView) -> Bool {
            tableView.isDragging || tableView.isDecelerating || tableView.isTracking
        }

        private func isRefreshControlActive(on tableView: UITableView) -> Bool {
            if tableView.refreshControl?.isRefreshing == true {
                return true
            }

            guard let deadline = refreshControlSettleDeadline else {
                return false
            }

            if Date().timeIntervalSinceReferenceDate < deadline {
                return true
            }

            refreshControlSettleDeadline = nil
            return false
        }

        private func restorePrependOffset(_ snapshot: PrependPositionSnapshot, in tableView: UITableView) {
            guard isReadyForLayout(tableView) else { return }
            layoutIfReady(tableView)
            let insertedHeight = tableView.contentSize.height - snapshot.contentHeight
            guard insertedHeight > 0 else { return }
            let targetOffsetY = snapshot.contentOffsetY + insertedHeight
            setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: clampedOffsetY(targetOffsetY, in: tableView)),
                on: tableView,
                animated: false,
                reason: "restorePrepend insertedHeight=\(format(insertedHeight)) snapshotOffset=\(format(snapshot.contentOffsetY))"
            )
        }

        private func restore(_ anchor: VisibleMessageAnchor, in tableView: UITableView) {
            guard isReadyForLayout(tableView) else { return }
            guard let row = messages.firstIndex(where: { $0.id == anchor.messageID }) else { return }
            let indexPath = IndexPath(row: row, section: 0)
            layoutIfReady(tableView)
            let rect = tableView.rectForRow(at: indexPath)
            let targetOffsetY = targetOffsetY(for: anchor, rowRect: rect, in: tableView)
            setContentOffset(
                CGPoint(x: tableView.contentOffset.x, y: clampedOffsetY(targetOffsetY, in: tableView)),
                on: tableView,
                animated: false,
                reason: "restoreAnchor message=\(anchor.messageID)"
            )
        }

        private func evaluateScrollState(on scrollView: UIScrollView) {
            guard scrollView.window != nil, scrollView.bounds.height > 0 else { return }
            updateNearBottom(on: scrollView)
        }

        private func updateNearBottom(on scrollView: UIScrollView) {
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let distanceFromBottom = scrollView.contentSize.height - visibleBottom
            let nextIsNearBottom = distanceFromBottom <= parent.bottomAutoScrollThreshold
            guard nextIsNearBottom != isNearBottom else { return }
            isNearBottom = nextIsNearBottom
            emit { [parent] in parent.onNearBottomChange(nextIsNearBottom) }
        }

        private func scrollToBottomAfterLayout(
            on tableView: UITableView,
            animated: Bool,
            notifyInitialPosition: Bool
        ) {
            scrollToBottomAfterLayout(
                on: tableView,
                animated: animated,
                notifyInitialPosition: notifyInitialPosition,
                attempt: 0
            )
        }

        private func scrollToBottomAfterLayout(
            on tableView: UITableView,
            animated: Bool,
            notifyInitialPosition: Bool,
            attempt: Int
        ) {
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self, let tableView else { return }
                guard notifyInitialPosition || !self.isUserInteracting(with: tableView) else {
                    self.logScroll("scrollBottom.skipInteracting", on: tableView, details: "attempt=\(attempt)")
                    return
                }
                guard tableView.window != nil else {
                    self.logScroll("scrollBottom.queueNoWindow", on: tableView, details: "attempt=\(attempt)")
                    self.queueScrollToBottom(animated: animated, notifyInitialPosition: notifyInitialPosition)
                    return
                }
                guard tableView.bounds.height > 0 else {
                    guard attempt < 5 else {
                        self.logScroll("scrollBottom.queueNoBounds", on: tableView, details: "attempt=\(attempt)")
                        self.queueScrollToBottom(animated: animated, notifyInitialPosition: notifyInitialPosition)
                        return
                    }
                    self.logScroll("scrollBottom.retryNoBounds", on: tableView, details: "attempt=\(attempt)")
                    self.scrollToBottomAfterLayout(
                        on: tableView,
                        animated: animated,
                        notifyInitialPosition: notifyInitialPosition,
                        attempt: attempt + 1
                    )
                    return
                }
                self.logScroll("scrollBottom.fire", on: tableView, details: "animated=\(animated) notifyInitial=\(notifyInitialPosition) attempt=\(attempt)")
                guard self.scrollToBottom(on: tableView, animated: animated) else {
                    self.logScroll("scrollBottom.queueFailed", on: tableView)
                    self.queueScrollToBottom(animated: animated, notifyInitialPosition: notifyInitialPosition)
                    return
                }
                let heightAfterFirstPass = tableView.contentSize.height
                let settlePass = { [weak self, weak tableView] in
                    guard let self, let tableView else { return }
                    guard notifyInitialPosition || !self.isUserInteracting(with: tableView) else {
                        self.logScroll("scrollBottom.secondPass.skipInteracting", on: tableView)
                        return
                    }
                    self.logScroll("scrollBottom.secondPass", on: tableView, details: "notifyInitial=\(notifyInitialPosition)")
                    guard self.scrollToBottom(on: tableView, animated: false) else {
                        self.logScroll("scrollBottom.secondPass.queueFailed", on: tableView)
                        self.queueScrollToBottom(animated: false, notifyInitialPosition: notifyInitialPosition)
                        return
                    }
                    if notifyInitialPosition {
                        let heightDelta = abs(tableView.contentSize.height - heightAfterFirstPass)
                        let distanceFromBottom = self.distanceFromBottom(in: tableView)
                        let lastRowVisible = self.isLastMessageRowVisible(in: tableView)
                        if attempt < 40, (heightDelta > 1 || distanceFromBottom > 1 || !lastRowVisible) {
                            self.logScroll(
                                "scrollBottom.settleRetry",
                                on: tableView,
                                details: "attempt=\(attempt) heightDelta=\(self.format(heightDelta)) distance=\(self.format(distanceFromBottom)) lastVisible=\(lastRowVisible)"
                            )
                            self.scrollToBottomAfterLayout(
                                on: tableView,
                                animated: false,
                                notifyInitialPosition: true,
                                attempt: attempt + 1
                            )
                            return
                        }
                        self.pendingInitialBottomPosition = false
                        self.hasPositionedInitialMessages = true
                        self.emit { [parent = self.parent] in
                            parent.onInitialPositioned()
                        }
                    }
                }
                if notifyInitialPosition {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: settlePass)
                } else {
                    DispatchQueue.main.async(execute: settlePass)
                }
            }
        }

        @discardableResult
        private func scrollToBottom(on tableView: UITableView, animated: Bool) -> Bool {
            guard isReadyForLayout(tableView) else { return false }
            layoutIfReady(tableView)
            if !messages.isEmpty {
                let lastRow = IndexPath(row: messages.count - 1, section: 0)
                tableView.scrollToRow(at: lastRow, at: .bottom, animated: animated)
                if !animated {
                    layoutIfReady(tableView)
                }
            }
            if !messages.isEmpty, !isLastMessageRowVisible(in: tableView) {
                logScroll("scrollToBottom.waitLastRow", on: tableView)
            }
            let minimumOffsetY = -tableView.adjustedContentInset.top
            let maximumOffsetY = max(
                minimumOffsetY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            setContentOffset(
                CGPoint(x: 0, y: maximumOffsetY),
                on: tableView,
                animated: animated,
                reason: "scrollToBottom"
            )
            return true
        }

        private func distanceFromBottom(in tableView: UITableView) -> CGFloat {
            let visibleBottom = tableView.contentOffset.y
                + tableView.bounds.height
                - tableView.adjustedContentInset.bottom
            return max(0, tableView.contentSize.height - visibleBottom)
        }

        private func isLastMessageRowVisible(in tableView: UITableView) -> Bool {
            guard !messages.isEmpty else { return true }
            let lastRow = IndexPath(row: messages.count - 1, section: 0)
            return tableView.indexPathsForVisibleRows?.contains(lastRow) == true
        }

        private func setContentOffset(_ offset: CGPoint, on tableView: UITableView, animated: Bool, reason: String) {
            let before = tableView.contentOffset.y
            logScroll(
                "setContentOffset.begin",
                on: tableView,
                details: "reason=\(reason) targetY=\(format(offset.y)) beforeY=\(format(before)) animated=\(animated)"
            )
            isRestoringPosition = true
            tableView.setContentOffset(offset, animated: animated)
            logScroll(
                "setContentOffset.end",
                on: tableView,
                details: "reason=\(reason) afterY=\(format(tableView.contentOffset.y))"
            )
            DispatchQueue.main.async { [weak self] in
                self?.isRestoringPosition = false
            }
        }

        private func clampedOffsetY(_ offsetY: CGFloat, in tableView: UITableView) -> CGFloat {
            let minimumOffsetY = -tableView.adjustedContentInset.top
            let maximumOffsetY = max(
                minimumOffsetY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            return min(max(offsetY, minimumOffsetY), maximumOffsetY)
        }

        private func emit(_ action: @escaping () -> Void) {
            DispatchQueue.main.async(execute: action)
        }
    }
}

private final class ChatTableView: UITableView {
    var onDidMoveToWindow: ((UITableView) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyWhenReady()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyWhenReady()
    }

    private func notifyWhenReady() {
        guard window != nil else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.onDidMoveToWindow?(self)
        }
    }
}

private struct VisibleMessageAnchor {
    let messageID: String
    let offsetFromReferenceY: CGFloat
    let referenceFraction: CGFloat
}

private struct MessageRenderSignature: Hashable {
    let id: String
    let senderId: String
    let senderType: String
    let fromName: String?
    let fromAvatar: String?
    let toName: String?
    let toAvatar: String?
    let contentType: String
    let contentBody: String?
    let contentURL: String?
    let contentName: String?
    let contentSize: Int?
    let contentMetaSignature: String

    nonisolated init(message: Message) {
        self.id = message.id
        self.senderId = message.senderId
        self.senderType = message.senderType
        self.fromName = message.from.name
        self.fromAvatar = message.from.avatar
        self.toName = message.to.name
        self.toAvatar = message.to.avatar
        self.contentType = message.content.type
        self.contentBody = message.content.body
        self.contentURL = message.content.url
        self.contentName = message.content.name
        self.contentSize = message.content.size
        self.contentMetaSignature = message.content.renderMetadataSignature
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
        .background(Color.rcmsToolbarSurface)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.rcmsHairline)
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
                .fill(Color.rcmsControlSurface)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color.rcmsHairline, lineWidth: 1))

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

private struct ChatComposerBar: View {
    let photoPickerSelection: Binding<PhotosPickerItem?>
    @Binding var inputText: String
    let isInputFocused: FocusState<Bool>.Binding
    let placeholder: String
    let isComposerDisabled: Bool
    let isUploadingImage: Bool
    let isSendDisabled: Bool
    let activeSlashQuery: String?
    let slashSuggestionIdentity: String
    let activeSlashArgumentContext: SlashArgumentContext?
    let shouldShowSlashChoices: Bool
    let shouldShowSlashCommands: Bool
    let isActiveSlashAutocompletePending: Bool
    let filteredSlashChoices: [SlashCommandChoice]
    let filteredSlashCommands: [SlashCommand]
    let selectedSlashCommandIndex: Int
    let choiceDetailText: (SlashCommandChoice, SlashCommandArg) -> String
    let onSlashSuggestionIdentityChange: () -> Void
    let onSelectSlashChoice: (SlashCommandChoice, SlashArgumentContext) -> Void
    let onSelectSlashCommand: (SlashCommand) -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            SlashSuggestionsPanel(
                activeSlashArgumentContext: activeSlashArgumentContext,
                shouldShowSlashChoices: shouldShowSlashChoices,
                shouldShowSlashCommands: shouldShowSlashCommands,
                isActiveSlashAutocompletePending: isActiveSlashAutocompletePending,
                filteredSlashChoices: filteredSlashChoices,
                filteredSlashCommands: filteredSlashCommands,
                selectedSlashCommandIndex: selectedSlashCommandIndex,
                choiceDetailText: choiceDetailText,
                onSelectSlashChoice: onSelectSlashChoice,
                onSelectSlashCommand: onSelectSlashCommand
            )

            HStack(alignment: .bottom, spacing: 8) {
                imagePickerButton(systemName: "plus", isUploading: false)
                imagePickerButton(systemName: "photo", isUploading: isUploadingImage)

                composerTextField

                ChatSendButton(isDisabled: isSendDisabled, action: onSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color.rcmsToolbarSurface)
        .background(.ultraThinMaterial)
    }

    private var composerTextField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $inputText, axis: .vertical)
                .focused(isInputFocused)
                .lineLimit(1...5)
                .textInputAutocapitalization(activeSlashQuery == nil ? .sentences : .never)
                .autocorrectionDisabled(activeSlashQuery != nil)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .foregroundStyle(Color.rcmsTextPrimary)
                .disabled(isComposerDisabled)
                .onChange(of: slashSuggestionIdentity) { _, _ in
                    onSlashSuggestionIdentityChange()
                }
        }
        .background(Color.rcmsFieldSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }

    private func imagePickerButton(systemName: String, isUploading: Bool) -> some View {
        PhotosPicker(selection: photoPickerSelection, matching: .images) {
            ChatComposerIconButton(systemName: systemName, isUploading: isUploading)
        }
        .disabled(isComposerDisabled)
    }
}

private struct SlashSuggestionsPanel: View {
    let activeSlashArgumentContext: SlashArgumentContext?
    let shouldShowSlashChoices: Bool
    let shouldShowSlashCommands: Bool
    let isActiveSlashAutocompletePending: Bool
    let filteredSlashChoices: [SlashCommandChoice]
    let filteredSlashCommands: [SlashCommand]
    let selectedSlashCommandIndex: Int
    let choiceDetailText: (SlashCommandChoice, SlashCommandArg) -> String
    let onSelectSlashChoice: (SlashCommandChoice, SlashArgumentContext) -> Void
    let onSelectSlashCommand: (SlashCommand) -> Void

    var body: some View {
        if let argContext = activeSlashArgumentContext, shouldShowSlashChoices {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredSlashChoices.isEmpty && isActiveSlashAutocompletePending {
                        SlashLoadingSuggestionRow()
                    }

                    ForEach(Array(filteredSlashChoices.enumerated()), id: \.element.id) { index, choice in
                        SlashChoiceSuggestionRow(
                            choice: choice,
                            detailText: choiceDetailText(choice, argContext.arg),
                            isSelected: index == selectedSlashCommandIndex,
                            action: {
                                onSelectSlashChoice(choice, argContext)
                            }
                        )

                        if index < filteredSlashChoices.count - 1 {
                            suggestionDivider
                        }
                    }
                }
            }
            .modifier(SlashSuggestionPanelChrome(
                maxHeight: panelHeight(
                    itemCount: filteredSlashChoices.count,
                    isLoading: filteredSlashChoices.isEmpty && isActiveSlashAutocompletePending
                )
            ))
        } else if shouldShowSlashCommands {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSlashCommands.enumerated()), id: \.element.id) { index, command in
                        SlashCommandSuggestionRow(
                            command: command,
                            isSelected: index == selectedSlashCommandIndex,
                            action: {
                                onSelectSlashCommand(command)
                            }
                        )

                        if index < filteredSlashCommands.count - 1 {
                            suggestionDivider
                        }
                    }
                }
            }
            .modifier(SlashSuggestionPanelChrome(maxHeight: panelHeight(itemCount: filteredSlashCommands.count)))
        }
    }

    private var suggestionDivider: some View {
        Divider()
            .padding(.leading, 42)
    }

    private func panelHeight(itemCount: Int, isLoading: Bool = false) -> CGFloat {
        let visibleRows = max(itemCount, isLoading ? 1 : 0)
        return min(CGFloat(max(visibleRows, 1)) * 50, 300)
    }
}

private struct SlashLoadingSuggestionRow: View {
    var body: some View {
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
}

private struct SlashChoiceSuggestionRow: View {
    let choice: SlashCommandChoice
    let detailText: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
                    Text(detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.rcmsAccent.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

private struct SlashCommandSuggestionRow: View {
    let command: SlashCommand
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .background(isSelected ? Color.rcmsAccent.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

private struct SlashSuggestionPanelChrome: ViewModifier {
    let maxHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: maxHeight)
            .background(Color.rcmsSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.rcmsHairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

private struct ChatSendButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
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
        }
    }

    private var shouldRenderMarkdown: Bool {
        Self.shouldRenderMarkdown(text)
    }

    static func shouldRenderMarkdown(_ text: String) -> Bool {
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
                    HStack(alignment: .center, spacing: 8) {
                        if let language = configuration.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                            Text(language.uppercased())
                                .font(ChatCodeTypography.labelFont())
                                .foregroundStyle(isMe ? Color.white.opacity(0.7) : Color.rcmsTextSecondary)
                        }

                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .center)
                    .padding(.horizontal, 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        ChatHighlightedCodeView(
                            code: configuration.content,
                            language: configuration.language,
                            isMe: isMe
                        )
                            .fixedSize(horizontal: true, vertical: false)
                            .lineSpacing(3)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 10)
                    }
                }
                .background(isMe ? Color.black.opacity(0.2) : Color.rcmsCodeBlockBackground)
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
    /// Pre-computed by `MessageRenderPipeline`; cached in `Coordinator` so the view
    /// body never calls the pipeline or re-parses markdown/code-fences.
    let rendered: RenderedMessage
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

    private var isAudioMessage: Bool {
        message.content.isAudio
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
            colors: [Color.rcmsSurfaceSolid, Color.rcmsSurfaceMuted],
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

                RenderedMessageBubble(
                    rendered: rendered,
                    isMe: isMe,
                    onPreviewImage: onPreviewImage.map { callback in { callback(message) } }
                )

                if messageTimestamp != nil || message.pending {
                    deliveryStatusRow
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
        .overlay(Circle().stroke(Color.rcmsAvatarBorder, lineWidth: 1))
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

    private var deliveryStatusRow: some View {
        HStack(spacing: 4) {
            if let messageTimestamp {
                Text(messageTimestamp)
            }

            if message.pending {
                if messageTimestamp != nil {
                    Text("·")
                }

                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.72)
                    .frame(width: 10, height: 10)

                Text("发送中")
            }
        }
        .font(.caption2)
        .foregroundStyle(message.pending ? Color.rcmsWarning : Color.rcmsTextSecondary)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(deliveryStatusAccessibilityLabel)
    }

    private var deliveryStatusAccessibilityLabel: String {
        let pieces = [messageTimestamp, message.pending ? "发送中" : nil]
            .compactMap { $0 }
        return pieces.joined(separator: " ")
    }

    private var imageMessageView: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 8) {
            imageThumbnailView

            if let imageCaption {
                messageTextBubble(imageCaption)
            }
        }
    }

    @ViewBuilder
    private func messageTextBubble(_ text: String) -> some View {
        let bubbleShape = BubbleShape(isMe: isMe)
        if MessageMarkdownView.shouldRenderMarkdown(text) {
            MessageMarkdownView(text: text, isMe: isMe)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
                .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
                .clipShape(bubbleShape)
                .contentShape(bubbleShape)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        } else {
            MessageMarkdownView(text: text, isMe: isMe)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
                .foregroundStyle(isMe ? .white : Color.rcmsTextPrimary)
                .clipShape(bubbleShape)
                .contentShape(bubbleShape)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
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
                    .stroke(isMe ? Color.white.opacity(0.2) : Color.rcmsImageBorder, lineWidth: message.content.isSticker ? 0 : 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)

        if let onPreviewImage {
            thumbnail
                .contentShape(RoundedRectangle(cornerRadius: message.content.isSticker ? 18 : 20, style: .continuous))
                .onTapGesture {
                    onPreviewImage(message)
                }
        } else {
            thumbnail
        }
    }
}

private struct ChatAudioMessageBubble: View {
    let message: Message
    let isMe: Bool

    @StateObject private var playback = ChatAudioPlaybackController()

    private var durationSeconds: Int? {
        message.content.audioDurationSeconds
    }

    private var bubbleWidth: CGFloat {
        guard let durationSeconds else { return 118 }
        let clamped = min(max(durationSeconds, 1), 60)
        return 98 + CGFloat(clamped) * 1.7
    }

    private var durationLabel: String {
        if let durationSeconds {
            return "\(durationSeconds)\""
        }
        if let size = message.content.size ?? message.content.asset?.size, size > 0 {
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        return "语音"
    }

    private var audioURL: URL? {
        APIClient.shared.resolvedURL(from: message.content.audioURLString)
    }

    var body: some View {
        Button {
            playback.toggle(url: audioURL)
        } label: {
            HStack(spacing: 10) {
                if !isMe {
                    playbackIcon
                    ChatAudioWaveform(isPlaying: playback.isPlaying, isMe: isMe)
                    Spacer(minLength: 4)
                    durationText
                } else {
                    durationText
                    Spacer(minLength: 4)
                    ChatAudioWaveform(isPlaying: playback.isPlaying, isMe: isMe)
                    playbackIcon
                }
            }
            .frame(width: bubbleWidth, alignment: isMe ? .trailing : .leading)
            .frame(minHeight: 32)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(isMe ? Color.rcmsAccent : Color.rcmsIncomingBubble)
            .clipShape(BubbleShape(isMe: isMe))
            .contentShape(BubbleShape(isMe: isMe))
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear {
            playback.pause()
        }
    }

    private var playbackIcon: some View {
        ZStack {
            Circle()
                .fill(isMe ? Color.white.opacity(0.18) : Color.rcmsAccent.opacity(0.12))
                .frame(width: 26, height: 26)

            if playback.isLoading {
                ProgressView()
                    .tint(isMe ? .white : Color.rcmsAccent)
                    .scaleEffect(0.72)
            } else {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isMe ? Color.white : Color.rcmsAccent)
                    .offset(x: playback.isPlaying ? 0 : 1)
            }
        }
    }

    private var durationText: some View {
        Text(playback.didFail ? "无法播放" : durationLabel)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isMe ? Color.white.opacity(0.92) : Color.rcmsTextSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(minWidth: 28, alignment: isMe ? .leading : .trailing)
    }

    private var accessibilityLabel: String {
        if playback.didFail {
            return "语音无法播放"
        }
        return playback.isPlaying ? "暂停语音消息" : "播放语音消息"
    }
}

struct ChatAudioWaveform: View {
    let isPlaying: Bool
    let isMe: Bool

    private let heights: [CGFloat] = [7, 13, 18, 11, 23, 15, 9, 19, 14, 22, 10, 16]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(isMe ? Color.white.opacity(0.82) : Color.rcmsAccent.opacity(0.72))
                    .frame(width: 3, height: heights[index])
                    .opacity(isPlaying ? playingOpacity(for: index) : 0.58)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index % 4) * 0.06),
                        value: isPlaying
                    )
            }
        }
        .frame(width: 69, height: 24)
    }

    private func playingOpacity(for index: Int) -> Double {
        index.isMultiple(of: 3) ? 0.48 : 0.94
    }
}

final class ChatAudioPlaybackController: ObservableObject {
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var didFail = false

    private var player: AVPlayer?
    private var currentURL: URL?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    func toggle(url: URL?) {
        guard let url else {
            markFailed()
            return
        }

        if currentURL == url, isPlaying {
            pause()
            return
        }

        if currentURL != url {
            prepare(url: url)
        }

        didFail = false
        isLoading = true
        player?.play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        isLoading = false
    }

    private func prepare(url: URL) {
        cleanupObservers()
        currentURL = url

        // 切换到 .playback 类别：走扬声器外放，不受静音键影响。
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .failed {
                    self?.markFailed()
                }
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isLoading = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finishPlayback()
        }
    }

    private func finishPlayback() {
        player?.seek(to: .zero)
        isPlaying = false
        isLoading = false
    }

    private func markFailed() {
        player?.pause()
        didFail = true
        isPlaying = false
        isLoading = false
    }

    private func cleanupObservers() {
        statusObservation = nil
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        cleanupObservers()
        player?.pause()
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
                .fill(Color.rcmsSurfaceElevated)

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
        if let asset = message.content.asset,
           let width = asset.width,
           let height = asset.height,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }

        if !message.content.isSticker,
           let width = message.content.meta?["width"]?.intValue,
           let height = message.content.meta?["height"]?.intValue,
           width > 0,
           height > 0 {
            return CGFloat(width) / CGFloat(height)
        }

        if message.content.isSticker {
            return 1
        }

        return 4 / 3
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

private struct ChatImageSaveStatus: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ChatImageSaveError: LocalizedError {
    case accessDenied
    case imageUnavailable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "请在系统设置中允许 ClawChat 添加照片，然后再试一次。"
        case .imageUnavailable:
            return "图片还没有加载完成，或原图地址不可用。"
        case .saveFailed:
            return "系统相册没有完成保存，请稍后再试。"
        }
    }
}

private enum ChatImageSaver {
    static func save(_ message: Message) async throws {
        let authorizationStatus = await requestAuthorizationIfNeeded()
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw ChatImageSaveError.accessDenied
        }

        guard let fileURL = await LocalImageStore.shared.ensureCachedImage(for: message) else {
            throw ChatImageSaveError.imageUnavailable
        }

        guard let image = await decodedImage(from: fileURL) else {
            throw ChatImageSaveError.imageUnavailable
        }

        try await saveUIImageToPhotoLibrary(image)
    }

    private static func saveUIImageToPhotoLibrary(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { didSave, error in
                resumeSaveContinuation(continuation, didSave: didSave, error: error)
            }
        }
    }

    private static func resumeSaveContinuation(
        _ continuation: CheckedContinuation<Void, Error>,
        didSave: Bool,
        error: Error?
    ) {
        if let error {
            continuation.resume(throwing: error)
        } else if didSave {
            continuation.resume()
        } else {
            continuation.resume(throwing: ChatImageSaveError.saveFailed)
        }
    }

    private static func decodedImage(from fileURL: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: fileURL.path)
        }.value
    }

    private static func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .notDetermined else {
            return status
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
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
    @State private var isSaving = false
    @State private var saveStatus: ChatImageSaveStatus?
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

                    Button {
                        saveImage()
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
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
        .alert(item: $saveStatus) { status in
            Alert(
                title: Text(status.title),
                message: Text(status.message),
                dismissButton: .default(Text("确定"))
            )
        }
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

    private func saveImage() {
        guard !isSaving else { return }

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await ChatImageSaver.save(message)
                saveStatus = ChatImageSaveStatus(title: "已保存", message: "图片已保存到系统相册。")
            } catch {
                saveStatus = ChatImageSaveStatus(
                    title: "保存失败",
                    message: error.localizedDescription
                )
            }
        }
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

#if DEBUG
struct ChatRoomUITestHarness: View {
    init() {
        ChatPreviewData.prepareScrollProbeFixtureIfNeeded()
    }

    var body: some View {
        ChatRoomView(
            previewContext: ChatContext(
                id: ChatPreviewData.scrollProbeConversationID,
                title: "Chat Scroll Test",
                subtitle: "UI test fixture",
                isGroup: true,
                groupId: "chat-scroll-test",
                memberCount: 12
            ),
            messages: ChatPreviewData.scrollProbeInitialMessages,
            connectionState: .connected,
            currentUserID: "preview-user"
        )
        .accessibilityIdentifier("chat-room-scroll-test")
    }
}
#endif

private enum ChatPreviewData {
    static let scrollProbeConversationID = "chat/group/chat-scroll-test"
    private static let scrollProbeMessageCount = 180
    private static var didPrepareScrollProbeFixture = false

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

    static let scrollProbeMessages: [Message] = (1...scrollProbeMessageCount).map { index in
        let isCurrentUser = index % 4 == 0
        let senderID = isCurrentUser ? "preview-user" : "scroll-bot-\(index % 5)"
        let senderName = isCurrentUser ? "You" : "Scroll Bot \(index % 5)"
        let senderType = isCurrentUser ? "user" : "bot"

        if index % 10 == 6 {
            return imageMessage(
                id: String(format: "scroll-%03d", index),
                conversationID: scrollProbeConversationID,
                senderType: senderType,
                senderID: senderID,
                senderName: senderName,
                caption: scrollProbeImageCaption(for: index),
                seq: index,
                timestamp: 1_779_070_000 + Int64(index * 60)
            )
        }

        return message(
            id: String(format: "scroll-%03d", index),
            conversationID: scrollProbeConversationID,
            senderType: senderType,
            senderID: senderID,
            senderName: senderName,
            body: scrollProbeBody(for: index),
            seq: index,
            timestamp: 1_779_070_000 + Int64(index * 60)
        )
    }

    static let scrollProbeInitialMessages = Array(scrollProbeMessages.suffix(50))

    @MainActor
    static func prepareScrollProbeFixtureIfNeeded() {
        guard !didPrepareScrollProbeFixture else { return }
        didPrepareScrollProbeFixture = true

        for message in scrollProbeMessages where message.content.type.lowercased() == "image" {
            guard let width = message.content.meta?["width"]?.intValue,
                  let height = message.content.meta?["height"]?.intValue,
                  let data = scrollProbeImageData(width: width, height: height, seed: message.seq ?? 0)
            else {
                continue
            }
            LocalImageStore.shared.cacheImageData(data, for: message)
        }

        LocalMessageStore.shared.upsert(messages: scrollProbeMessages)
    }

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

    private static func imageMessage(
        id: String,
        conversationID: String,
        senderType: String,
        senderID: String,
        senderName: String,
        caption: String,
        seq: Int,
        timestamp: Int64
    ) -> Message {
        let dimensions = scrollProbeImageDimensions(for: seq)
        return Message(
            id: id,
            conversationId: conversationID,
            topic: conversationID,
            senderId: senderID,
            senderType: senderType,
            from: ChatPeer(type: senderType, id: senderID, name: senderName, avatar: nil),
            to: ChatPeer(type: "user", id: "preview-user", name: "You", avatar: nil),
            content: MessageContent(
                type: "image",
                body: caption,
                url: nil,
                name: "scroll-probe-\(seq).png",
                size: nil,
                meta: [
                    "width": AnyCodable(dimensions.width),
                    "height": AnyCodable(dimensions.height)
                ]
            ),
            seq: seq,
            timestamp: timestamp,
            createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
        )
    }

    private static func scrollProbeBody(for index: Int) -> String {
        let label = String(format: "Scroll probe %03d", index)

        switch index % 9 {
        case 0:
            return "\(label)\n\n```swift\nlet row = \(index)\nprint(\"stable height\")\n```"
        case 1:
            return "\(label): short status update."
        case 2:
            return "\(label)\n\n- first bullet wraps on narrow screens\n- second bullet keeps the row self-sizing honest\n- third bullet checks markdown spacing"
        case 3:
            return "\(label) " + String(repeating: "This is a deliberately long chat message used to exercise wrapping and measured row height. ", count: 3)
        case 4:
            return "\(label)\nLine one\nLine two\nLine three\nLine four"
        case 5:
            return "\(label)\n\n> Quoted markdown should keep a compact bubble height.\n\nA follow-up paragraph keeps the row from being too small."
        case 6:
            return "\(label)\n\n| Item | State |\n| --- | --- |\n| Images | ready |\n| Markdown | stable |\n| Scroll | smooth |"
        case 7:
            return "\(label)\n\n### Markdown section\n\n1. Numbered item with wrapping text\n2. Another item with `inline code`\n3. Final item after a blank line"
        default:
            return "\(label): final confirmation with inline `code`, **bold text**, _emphasis_, and enough content to avoid identical rows."
        }
    }

    private static func scrollProbeImageCaption(for index: Int) -> String {
        let label = String(format: "Image probe %03d", index)
        return "\(label)\n\n**Markdown caption** with `inline code`, a [link](https://example.com), and enough wrapped text to test image-plus-markdown row sizing."
    }

    private static func scrollProbeImageDimensions(for index: Int) -> (width: Int, height: Int) {
        switch index % 4 {
        case 0:
            return (width: 1200, height: 800)
        case 1:
            return (width: 900, height: 1200)
        case 2:
            return (width: 640, height: 640)
        default:
            return (width: 1400, height: 700)
        }
    }

    @MainActor
    private static func scrollProbeImageData(width: Int, height: Int, seed: Int) -> Data? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            let hue = CGFloat(seed % 17) / 17.0
            UIColor(hue: hue, saturation: 0.55, brightness: 0.94, alpha: 1).setFill()
            context.fill(rect)

            UIColor(white: 1, alpha: 0.82).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))

            let text = "Image probe \(String(format: "%03d", seed))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: max(32, min(size.width, size.height) * 0.08), weight: .bold),
                .foregroundColor: UIColor(white: 0.12, alpha: 1)
            ]
            let textRect = CGRect(x: size.width * 0.08, y: size.height * 0.68, width: size.width * 0.84, height: size.height * 0.2)
            text.draw(in: textRect, withAttributes: attributes)
        }
        return image.pngData()
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
        self.pending = false
    }
}
