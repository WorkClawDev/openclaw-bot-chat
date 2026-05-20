import SwiftUI
import Combine

struct HomeDashboardMetrics: Equatable {
    let totalBots: Int
    let onlineBots: Int
    let totalGroups: Int
    let activeGroups: Int
    let totalConversations: Int
    let unreadMessages: Int

    init(bots: [Bot], groups: [ChatGroup], conversations: [Conversation]) {
        totalBots = bots.count
        onlineBots = bots.filter { $0.status == "online" }.count
        totalGroups = groups.count
        activeGroups = groups.filter { $0.isActive == true }.count
        totalConversations = conversations.count
        unreadMessages = conversations.reduce(0) { total, conversation in
            total + max(conversation.unreadCount ?? 0, 0)
        }
    }
}

final class HomeDashboardViewModel: ObservableObject {
    @Published private(set) var bots: [Bot] = []
    @Published private(set) var groups: [ChatGroup] = []
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let refreshInterval: TimeInterval = 45
    private var cancellables = Set<AnyCancellable>()
    private var hasHydratedCache = false
    private var hasLoaded = false
    private var lastRefreshAt: Date?

    var metrics: HomeDashboardMetrics {
        HomeDashboardMetrics(bots: bots, groups: groups, conversations: conversations)
    }

    var recentConversations: [Conversation] {
        conversations.sorted { lhs, rhs in
            let leftTimestamp = lhs.lastMessage?.timestamp ?? Int64.min
            let rightTimestamp = rhs.lastMessage?.timestamp ?? Int64.min
            if leftTimestamp != rightTimestamp {
                return leftTimestamp > rightTimestamp
            }
            return lhs.id < rhs.id
        }
    }

    func refreshIfNeeded(force: Bool = false) {
        if isLoading {
            return
        }

        if !force {
            hydrateCachedSnapshotIfNeeded()
        }

        if !force, hasLoaded, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < refreshInterval {
            return
        }

        errorMessage = nil
        isLoading = true

        let botsRequest: AnyPublisher<[Bot], Error> = APIClient.shared.request("/api/v1/bots")
        let groupsRequest: AnyPublisher<[ChatGroup], Error> = APIClient.shared.request("/api/v1/groups")
        let conversationsRequest: AnyPublisher<[Conversation], Error> = APIClient.shared.request("/api/v1/conversations")

        Publishers.Zip3(botsRequest, groupsRequest, conversationsRequest)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                if case .failure(let error) = completion {
                    self?.errorMessage = error.localizedDescription
                }
            } receiveValue: { [weak self] bots, groups, conversations in
                LocalMessageStore.shared.upsert(bots: bots)
                LocalMessageStore.shared.upsert(groups: groups)
                LocalMessageStore.shared.upsert(conversations: conversations)
                self?.bots = bots
                self?.groups = groups
                self?.conversations = conversations
                self?.hasHydratedCache = true
                self?.hasLoaded = true
                self?.lastRefreshAt = Date()
            }
            .store(in: &cancellables)
    }

    private func hydrateCachedSnapshotIfNeeded() {
        guard !hasHydratedCache else { return }

        let cachedBots = LocalMessageStore.shared.cachedBots()
        let cachedGroups = LocalMessageStore.shared.cachedGroups()
        let cachedConversations = LocalMessageStore.shared.cachedConversations()

        if !cachedBots.isEmpty {
            bots = cachedBots
        }
        if !cachedGroups.isEmpty {
            groups = cachedGroups
        }
        if !cachedConversations.isEmpty {
            conversations = cachedConversations
        }
        hasHydratedCache = true
    }
}

struct HomeDashboardView: View {
    @StateObject private var viewModel = HomeDashboardViewModel()
    @ObservedObject private var authManager = AuthManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header

                        messagesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                viewModel.refreshIfNeeded()
            }
            .refreshable {
                viewModel.refreshIfNeeded(force: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Messages")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rcmsTextStrong)

                Text("Welcome back")
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }

            Spacer()

            AvatarBadge(
                name: authManager.currentUser?.nickname ?? authManager.currentUser?.username ?? "User",
                imageURL: authManager.currentUser?.avatarUrl ?? authManager.currentUser?.avatar,
                diameter: 50,
                statusColor: nil
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chats")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let errorMessage = viewModel.errorMessage, viewModel.recentConversations.isEmpty {
                HomeEmptyState(
                    systemImage: "exclamationmark.triangle.fill",
                    title: "Dashboard unavailable",
                    message: errorMessage
                )
            } else if viewModel.recentConversations.isEmpty {
                HomeEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "No conversations yet",
                    message: "Start a chat from Bots or Groups."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentConversations) { conversation in
                        NavigationLink {
                            ChatRoomView(context: chatContext(for: conversation))
                        } label: {
                            DashboardConversationRow(
                                title: conversationTitle(for: conversation),
                                subtitle: conversation.lastMessage?.content ?? "No messages yet",
                                timestamp: timestamp(for: conversation),
                                unreadCount: conversation.unreadCount,
                                avatarURL: conversationAvatarURL(for: conversation),
                                systemImage: conversationSystemImage(for: conversation)
                            )
                        }
                        .buttonStyle(.plain)

                        if conversation.id != viewModel.recentConversations.last?.id {
                            Divider()
                                .padding(.leading, 72)
                        }
                    }
                }
                .glassCardStyle()
            }
        }
    }

    private func chatContext(for conversation: Conversation) -> ChatContext {
        switch conversation.type.lowercased() {
        case "group":
            if let group = matchingGroup(for: conversation) {
                return ChatContext(
                    id: conversationTopic(for: group),
                    title: group.name,
                    subtitle: (group.isActive == true) ? "bots online" : "bots offline",
                    isGroup: true,
                    groupId: group.id.uuidString.lowercased(),
                    memberCount: group.memberCount,
                    avatarURLString: group.avatarUrl ?? group.avatar
                )
            }

            let groupId = conversationTargetID(for: conversation)
            return ChatContext(
                id: conversation.id,
                title: conversationTitle(for: conversation),
                subtitle: "group chat",
                isGroup: true,
                groupId: groupId,
                avatarURLString: conversation.avatar
            )

        default:
            if let bot = matchingBot(for: conversation) {
                return ChatContext(
                    id: conversationTopic(for: bot) ?? conversation.id,
                    title: bot.name,
                    subtitle: bot.status == "online" ? "online" : "offline",
                    isGroup: false,
                    groupId: nil,
                    bot: bot,
                    avatarURLString: bot.avatarUrl ?? bot.avatar
                )
            }

            return ChatContext(
                id: conversation.id,
                title: conversationTitle(for: conversation),
                subtitle: conversation.type.lowercased() == "bot" ? "bot chat" : "chat",
                isGroup: false,
                groupId: nil,
                avatarURLString: conversation.avatar
            )
        }
    }

    private func conversationTitle(for conversation: Conversation) -> String {
        switch conversation.type.lowercased() {
        case "group":
            if let group = matchingGroup(for: conversation) {
                return group.name
            }
        default:
            if let bot = matchingBot(for: conversation) {
                return bot.name
            }
        }

        return conversation.name
    }

    private func conversationAvatarURL(for conversation: Conversation) -> String? {
        switch conversation.type.lowercased() {
        case "group":
            if let group = matchingGroup(for: conversation) {
                return group.avatarUrl ?? group.avatar ?? conversation.avatar
            }
        default:
            if let bot = matchingBot(for: conversation) {
                return bot.avatarUrl ?? bot.avatar ?? conversation.avatar
            }
        }

        return conversation.avatar
    }

    private func conversationSystemImage(for conversation: Conversation) -> String {
        conversation.type.lowercased() == "group" ? "person.3.fill" : "bubble.left.fill"
    }

    private func matchingGroup(for conversation: Conversation) -> ChatGroup? {
        let targetID = conversationTargetID(for: conversation)
        return viewModel.groups.first { group in
            let groupID = group.id.uuidString.lowercased()
            return targetID == groupID
                || conversation.id == conversationTopic(for: group)
        }
    }

    private func matchingBot(for conversation: Conversation) -> Bot? {
        let targetID = conversationTargetID(for: conversation)
        return viewModel.bots.first { bot in
            let botID = bot.id.uuidString.lowercased()
            return targetID == botID
                || conversation.id == conversationTopic(for: bot)
        }
    }

    private func conversationTargetID(for conversation: Conversation) -> String? {
        if let targetId = conversation.targetId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !targetId.isEmpty {
            return targetId
        }

        let parts = conversation.id.split(separator: "/").map(String.init)
        if parts.count >= 3, parts[0] == "chat", parts[1] == "group" {
            return parts[2].lowercased()
        }
        if let botIndex = parts.firstIndex(of: "bot"), botIndex + 1 < parts.count {
            return parts[botIndex + 1].lowercased()
        }
        return nil
    }

    private func conversationTopic(for group: ChatGroup) -> String {
        if let mqttTopic = group.mqttTopic, !mqttTopic.isEmpty {
            return mqttTopic
        }
        return "chat/group/\(group.id.uuidString.lowercased())"
    }

    private func conversationTopic(for bot: Bot) -> String? {
        if let mqttTopic = bot.mqttTopic, !mqttTopic.isEmpty {
            return mqttTopic
        }
        guard let userID = authManager.currentUser?.id.uuidString.lowercased() else {
            return nil
        }
        return "chat/dm/user/\(userID)/bot/\(bot.id.uuidString.lowercased())"
    }

    private func timestamp(for conversation: Conversation) -> String? {
        guard let date = conversation.lastMessage?.displayDate else {
            return nil
        }

        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }

        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.dayFormatter.string(from: date)
        }

        return Self.yearFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()
}

private struct HomeEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.rcmsTextSecondary)

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.rcmsTextStrong)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .glassCardStyle()
    }
}

#Preview {
    HomeDashboardView()
}
