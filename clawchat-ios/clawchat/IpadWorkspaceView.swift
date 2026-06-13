import SwiftUI

private enum IpadWorkspaceSection: String, CaseIterable, Identifiable {
    case home
    case bots
    case groups
    case tasks
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return L10n.t("首页", "Home")
        case .tasks:
            return L10n.t("任务", "Tasks")
        case .bots:
            return L10n.t("机器人", "Bots")
        case .groups:
            return L10n.t("群组", "Groups")
        case .settings:
            return L10n.t("设置", "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "house.fill"
        case .tasks:
            return "checklist.checked"
        case .bots:
            return "cpu.fill"
        case .groups:
            return "person.3.fill"
        case .settings:
            return "gearshape.fill"
        }
    }
}

private enum IpadWorkspaceLayout {
    static let navigationRailWidth: CGFloat = 92
    static let contentColumnWidth: CGFloat = 340
    static let detailMaxWidth: CGFloat = 980
    static let profileDetailMaxWidth: CGFloat = 820
}

struct IpadWorkspaceView: View {
    @State private var selectedSection: IpadWorkspaceSection = .home
    @State private var selectedChatContext: ChatContext?
    @State private var selectedBotID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var botSearchText = ""
    @State private var groupSearchText = ""
    @AppStorage(AppLanguageMode.storageKey) private var languageModeRawValue = AppLanguageMode.english.rawValue

    @StateObject private var homeViewModel = HomeDashboardViewModel()
    @StateObject private var tasksViewModel = TasksViewModel()
    @StateObject private var botsViewModel = BotsViewModel()
    @StateObject private var groupsViewModel = GroupsViewModel()
    @ObservedObject private var authManager = AuthManager.shared
    @ObservedObject private var realtimeService = RealtimeService.shared

    init(launchSection: String? = nil) {
        _selectedSection = State(initialValue: Self.initialSection(from: launchSection))
    }

    private static func initialSection(from launchSection: String?) -> IpadWorkspaceSection {
        switch launchSection?.lowercased() {
        case "ipadworkspacetasks":
            return .tasks
        case "ipadworkspacebots":
            return .bots
        case "ipadworkspacegroups":
            return .groups
        case "ipadworkspacesettings":
            return .settings
        default:
            return .home
        }
    }

    private var filteredBots: [Bot] {
        let query = botSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return botsViewModel.bots }
        return botsViewModel.bots.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredGroups: [ChatGroup] {
        let query = groupSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupsViewModel.groups }
        return groupsViewModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        let _ = languageModeRawValue

        ZStack {
            FrostedBackground()

            HStack(spacing: 0) {
                IpadSidebarView(
                    selectedSection: $selectedSection,
                    user: authManager.currentUser,
                    connectionState: realtimeService.connectionState,
                    onSelect: { section in
                        if selectedSection != section {
                            selectedChatContext = nil
                        }
                        selectedSection = section
                    }
                )

                Divider()
                    .overlay(Color.rcmsDivider)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            refreshAllIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .home:
            IpadMessagesWorkspace(
                viewModel: homeViewModel,
                connectionState: realtimeService.connectionState,
                selectedChatContext: $selectedChatContext,
                contextForConversation: chatContext(for:),
                titleForConversation: conversationTitle(for:),
                avatarURLForConversation: conversationAvatarURL(for:),
                systemImageForConversation: conversationSystemImage(for:),
                timestampForConversation: timestamp(for:)
            )
        case .tasks:
            IpadDetailStage(maxWidth: IpadWorkspaceLayout.detailMaxWidth, alignment: .top) {
                TasksView(viewModel: tasksViewModel)
                    .id("ipad-tasks")
            }
        case .bots:
            IpadBotsWorkspace(
                viewModel: botsViewModel,
                bots: filteredBots,
                searchText: $botSearchText,
                selectedBotID: $selectedBotID,
                selectedChatContext: $selectedChatContext,
                contextForBot: chatContext(for:)
            )
        case .groups:
            IpadGroupsWorkspace(
                viewModel: groupsViewModel,
                groups: filteredGroups,
                searchText: $groupSearchText,
                selectedGroupID: $selectedGroupID,
                selectedChatContext: $selectedChatContext,
                contextForGroup: chatContext(for:)
            )
        case .settings:
            IpadDetailStage(maxWidth: IpadWorkspaceLayout.detailMaxWidth, alignment: .top) {
                SettingsView()
                    .id("ipad-settings")
            }
        }
    }

    private func refreshAllIfNeeded() {
        authManager.refreshCurrentUserIfNeeded()
        homeViewModel.refreshIfNeeded()
        Swift.Task { await tasksViewModel.load(showLoading: false) }
        botsViewModel.refreshIfNeeded()
        groupsViewModel.refreshIfNeeded()
    }

    private func chatContext(for conversation: Conversation) -> ChatContext {
        switch conversation.type.lowercased() {
        case "group":
            if let group = matchingGroup(for: conversation) {
                return chatContext(for: group)
            }

            let groupID = conversationTargetID(for: conversation)
            return ChatContext(
                id: conversation.id,
                title: conversationTitle(for: conversation),
                subtitle: L10n.groupChat,
                isGroup: true,
                groupId: groupID,
                avatarURLString: conversation.avatar
            )

        default:
            if let bot = matchingBot(for: conversation) {
                return chatContext(for: bot)
            }

            return ChatContext(
                id: conversation.id,
                title: conversationTitle(for: conversation),
                subtitle: conversation.type.lowercased() == "bot" ? L10n.botChat : L10n.chat,
                isGroup: false,
                groupId: nil,
                avatarURLString: conversation.avatar
            )
        }
    }

    private func chatContext(for bot: Bot) -> ChatContext {
        ChatContext(
            id: conversationTopic(for: bot) ?? bot.id.uuidString.lowercased(),
            title: bot.name,
            subtitle: bot.status == "online"
                ? "\(L10n.online) · \(L10n.bot)"
                : "\(L10n.offline) · \(L10n.bot)",
            isGroup: false,
            groupId: nil,
            bot: bot,
            avatarURLString: bot.avatarUrl ?? bot.avatar
        )
    }

    private func chatContext(for group: ChatGroup) -> ChatContext {
        ChatContext(
            id: conversationTopic(for: group),
            title: group.name,
            subtitle: group.isActive == true
                ? L10n.t("\(group.memberCount ?? 0) 名成员 · 机器人在线", "\(group.memberCount ?? 0) members · bots online")
                : L10n.t("\(group.memberCount ?? 0) 名成员 · 机器人离线", "\(group.memberCount ?? 0) members · bots offline"),
            isGroup: true,
            groupId: group.id.uuidString.lowercased(),
            memberCount: group.memberCount,
            avatarURLString: group.avatarUrl ?? group.avatar
        )
    }

    private func conversationTitle(for conversation: Conversation) -> String {
        switch conversation.type.lowercased() {
        case "group":
            return matchingGroup(for: conversation)?.name ?? conversation.name
        default:
            return matchingBot(for: conversation)?.name ?? conversation.name
        }
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
        conversation.type.lowercased() == "group" ? "person.3.fill" : "cpu.fill"
    }

    private func matchingGroup(for conversation: Conversation) -> ChatGroup? {
        let targetID = conversationTargetID(for: conversation)
        return groupsViewModel.groups.first { group in
            let groupID = group.id.uuidString.lowercased()
            return targetID == groupID || conversation.id == conversationTopic(for: group)
        }
    }

    private func matchingBot(for conversation: Conversation) -> Bot? {
        let targetID = conversationTargetID(for: conversation)
        return botsViewModel.bots.first { bot in
            let botID = bot.id.uuidString.lowercased()
            return targetID == botID || conversation.id == conversationTopic(for: bot)
        }
    }

    private func conversationTargetID(for conversation: Conversation) -> String? {
        if let targetID = conversation.targetId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !targetID.isEmpty {
            return targetID
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

private struct IpadSidebarView: View {
    @Binding var selectedSection: IpadWorkspaceSection
    let user: User?
    let connectionState: RealtimeConnectionState
    let onSelect: (IpadWorkspaceSection) -> Void

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("ClawChat")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.top, 20)

            VStack(spacing: 10) {
                ForEach(IpadWorkspaceSection.allCases) { section in
                    Button {
                        onSelect(section)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: section.systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(height: 22)

                            Text(section.title)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .foregroundStyle(selectedSection == section ? .white : Color.rcmsTextPrimary)
                        .frame(width: 64, height: 56)
                        .background(selectedSection == section ? Color.rcmsAccent : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(section.title)
                }
            }

            Spacer(minLength: 16)

            VStack(spacing: 14) {
                Circle()
                    .fill(connectionTint)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(connectionText)

                if let user {
                    AvatarBadge(
                        name: displayName(for: user),
                        imageURL: user.avatarUrl ?? user.avatar,
                        diameter: 42,
                        statusColor: Color.rcmsOnline
                    )
                    .accessibilityLabel(displayName(for: user))
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: IpadWorkspaceLayout.navigationRailWidth)
        .frame(maxHeight: .infinity)
        .background(Color.rcmsSurfaceSolid.opacity(0.62))
    }

    private var connectionText: String {
        switch connectionState {
        case .idle:
            return L10n.t("MQTT 空闲", "MQTT idle")
        case .connecting:
            return L10n.t("MQTT 连接中", "MQTT connecting")
        case .connected:
            return L10n.t("MQTT 已连接", "MQTT connected")
        case .disconnected:
            return L10n.t("MQTT 已断开", "MQTT disconnected")
        }
    }

    private var connectionTint: Color {
        switch connectionState {
        case .connected:
            return Color.rcmsOnline
        case .connecting:
            return Color.rcmsWarning
        case .idle, .disconnected:
            return Color.rcmsOffline
        }
    }

    private func displayName(for user: User) -> String {
        let nickname = user.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        return nickname?.isEmpty == false ? nickname! : user.username
    }
}

private struct IpadMessagesWorkspace: View {
    @ObservedObject var viewModel: HomeDashboardViewModel
    let connectionState: RealtimeConnectionState
    @Binding var selectedChatContext: ChatContext?
    let contextForConversation: (Conversation) -> ChatContext
    let titleForConversation: (Conversation) -> String
    let avatarURLForConversation: (Conversation) -> String?
    let systemImageForConversation: (Conversation) -> String
    let timestampForConversation: (Conversation) -> String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                metricStrip
                conversationList
            }
            .frame(width: IpadWorkspaceLayout.contentColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(Color.rcmsBackground.opacity(0.35))

            Divider()
                .overlay(Color.rcmsDivider)

            IpadDetailStage {
                detail
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("消息", "Messages"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("机器人和群组实时会话", "Realtime bot and group conversations"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }

                Spacer()

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            IpadSearchField(text: .constant(""), placeholder: L10n.t("搜索消息", "Search messages"))
                .disabled(true)
                .opacity(0.72)
        }
    }

    private var metricStrip: some View {
        let metrics = viewModel.metrics
        return HStack(spacing: 10) {
            IpadMiniMetric(title: L10n.t("在线机器人", "Online bots"), value: "\(metrics.onlineBots)", systemImage: "cpu.fill", tint: Color.rcmsOnline)
            IpadMiniMetric(title: L10n.t("活跃群组", "Active groups"), value: "\(metrics.activeGroups)", systemImage: "person.3.fill", tint: Color.rcmsAccent)
            IpadMiniMetric(title: L10n.t("消息通道", "Broker"), value: brokerMetricValue, systemImage: "antenna.radiowaves.left.and.right", tint: brokerMetricTint)
        }
    }

    private var brokerMetricValue: String {
        switch connectionState {
        case .connected:
            return L10n.t("在线", "Live")
        case .connecting:
            return L10n.t("同步", "Sync")
        case .idle:
            return L10n.t("空闲", "Idle")
        case .disconnected:
            return L10n.t("离线", "Off")
        }
    }

    private var brokerMetricTint: Color {
        switch connectionState {
        case .connected:
            return Color.rcmsOnline
        case .connecting:
            return Color.rcmsWarning
        case .idle, .disconnected:
            return Color.rcmsOffline
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("最近", "Recent"))
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)

            if let errorMessage = viewModel.errorMessage, viewModel.recentConversations.isEmpty {
                IpadEmptyPanel(systemImage: "exclamationmark.triangle.fill", title: L10n.t("消息面板不可用", "Dashboard unavailable"), message: errorMessage)
            } else if viewModel.recentConversations.isEmpty {
                IpadEmptyPanel(systemImage: "bubble.left.and.bubble.right", title: L10n.t("暂无会话", "No conversations yet"), message: L10n.t("从机器人或群组开始聊天。", "Start a chat from Bots or Groups."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.recentConversations) { conversation in
                            let context = contextForConversation(conversation)
                            Button {
                                selectedChatContext = context
                            } label: {
                                DashboardConversationRow(
                                    title: titleForConversation(conversation),
                                    subtitle: conversation.lastMessage?.content ?? L10n.noMessagesYet,
                                    timestamp: timestampForConversation(conversation),
                                    unreadCount: conversation.unreadCount,
                                    avatarURL: avatarURLForConversation(conversation),
                                    systemImage: systemImageForConversation(conversation),
                                    statusColor: conversation.type.lowercased() == "group" ? nil : Color.rcmsOnline
                                )
                                .padding(.horizontal, 8)
                                .background(selectedChatContext?.id == context.id ? Color.rcmsAccentSoft.opacity(0.86) : Color.clear)
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
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedChatContext {
            ChatRoomView(context: selectedChatContext)
        } else {
            IpadWorkspaceEmptyDetail(
                title: L10n.t("选择一个会话", "Pick up a conversation"),
                message: L10n.t("从列表中选择机器人或群组，聊天会在这里打开。", "Select a bot or group from the list. The chat opens here while navigation and context stay visible."),
                systemImage: "bubble.left.and.bubble.right.fill",
                highlights: [
                    (L10n.t("通道状态", "Broker status"), brokerMetricValue, brokerMetricTint),
                    (L10n.t("在线机器人", "Online bots"), "\(viewModel.metrics.onlineBots)", Color.rcmsOnline),
                    (L10n.t("活跃群组", "Active groups"), "\(viewModel.metrics.activeGroups)", Color.rcmsAccent)
                ]
            )
        }
    }
}

private struct IpadBotsWorkspace: View {
    @ObservedObject var viewModel: BotsViewModel
    let bots: [Bot]
    @Binding var searchText: String
    @Binding var selectedBotID: UUID?
    @Binding var selectedChatContext: ChatContext?
    let contextForBot: (Bot) -> ChatContext

    private var selectedBot: Bot? {
        if let selectedBotID, let bot = bots.first(where: { $0.id == selectedBotID }) {
            return bot
        }
        return bots.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                IpadDirectoryHeader(title: L10n.t("机器人", "Bots"), subtitle: L10n.t("机器人私聊和运行状态", "Bot direct chats and runtime presence"), isLoading: viewModel.isLoading)
                IpadSearchField(text: $searchText, placeholder: L10n.t("搜索机器人", "Search bots"))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(bots) { bot in
                            Button {
                                selectedBotID = bot.id
                                selectedChatContext = nil
                            } label: {
                                BotRowCard(bot: bot)
                                    .padding(.horizontal, 8)
                                    .background((selectedBotID ?? selectedBot?.id) == bot.id ? Color.rcmsAccentSoft.opacity(0.86) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glassCardStyle()
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: IpadWorkspaceLayout.contentColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            Divider()
                .overlay(Color.rcmsDivider)

            IpadDetailStage {
                if let selectedChatContext {
                    ChatRoomView(context: selectedChatContext)
                } else if let selectedBot {
                    IpadBotDetail(bot: selectedBot) {
                        selectedChatContext = contextForBot(selectedBot)
                    }
                } else if viewModel.errorMessage != nil {
                    IpadWorkspaceEmptyDetail(title: L10n.t("机器人不可用", "Bots unavailable"), message: viewModel.errorMessage ?? "", systemImage: "exclamationmark.triangle.fill")
                } else {
                    IpadWorkspaceEmptyDetail(title: L10n.t("暂无机器人", "No bots yet"), message: L10n.t("创建或连接机器人后即可开始私聊。", "Create or connect a bot to start a direct chat."), systemImage: "cpu.fill")
                }
            }
        }
    }
}

private struct IpadGroupsWorkspace: View {
    @ObservedObject var viewModel: GroupsViewModel
    let groups: [ChatGroup]
    @Binding var searchText: String
    @Binding var selectedGroupID: UUID?
    @Binding var selectedChatContext: ChatContext?
    let contextForGroup: (ChatGroup) -> ChatContext

    private var selectedGroup: ChatGroup? {
        if let selectedGroupID, let group = groups.first(where: { $0.id == selectedGroupID }) {
            return group
        }
        return groups.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                IpadDirectoryHeader(title: L10n.t("群组", "Groups"), subtitle: L10n.t("人与机器人共同参与的群聊", "Group rooms with humans and bots"), isLoading: viewModel.isLoading)
                IpadSearchField(text: $searchText, placeholder: L10n.t("搜索群组", "Search groups"))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groups) { group in
                            Button {
                                selectedGroupID = group.id
                                selectedChatContext = nil
                            } label: {
                                GroupRowCard(group: group)
                                    .padding(.horizontal, 8)
                                    .background((selectedGroupID ?? selectedGroup?.id) == group.id ? Color.rcmsAccentSoft.opacity(0.86) : Color.clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .glassCardStyle()
                }
                .scrollIndicators(.hidden)
            }
            .frame(width: IpadWorkspaceLayout.contentColumnWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            Divider()
                .overlay(Color.rcmsDivider)

            IpadDetailStage {
                if let selectedChatContext {
                    ChatRoomView(context: selectedChatContext)
                } else if let selectedGroup {
                    IpadGroupDetail(group: selectedGroup) {
                        selectedChatContext = contextForGroup(selectedGroup)
                    }
                } else if viewModel.errorMessage != nil {
                    IpadWorkspaceEmptyDetail(title: L10n.t("群组不可用", "Groups unavailable"), message: viewModel.errorMessage ?? "", systemImage: "exclamationmark.triangle.fill")
                } else {
                    IpadWorkspaceEmptyDetail(title: L10n.t("暂无群组", "No groups yet"), message: L10n.t("创建群组后即可把成员、机器人和实时历史放在一起。", "Create a group to combine humans, bots, and realtime history."), systemImage: "person.3.fill")
                }
            }
        }
    }
}

private struct IpadWorkspaceEmptyDetail: View {
    let title: String
    let message: String
    let systemImage: String
    var highlights: [(String, String, Color)] = []

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
                .frame(width: 72, height: 72)
                .background(Color.rcmsAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if !highlights.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(highlights.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 5) {
                            Text(item.1)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(item.2)
                                .lineLimit(1)
                                .minimumScaleFactor(0.74)
                            Text(item.0)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.rcmsTextSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(width: 118, height: 66)
                        .background(Color.rcmsSurfaceElevated.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.rcmsHairline, lineWidth: 1)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct IpadDetailStage<Content: View>: View {
    let maxWidth: CGFloat
    let alignment: Alignment
    private let content: Content

    init(
        maxWidth: CGFloat = IpadWorkspaceLayout.detailMaxWidth,
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.maxWidth = maxWidth
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: alignment) {
            content
                .frame(maxWidth: maxWidth, maxHeight: .infinity, alignment: alignment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .background(Color.rcmsBackground.opacity(0.18))
    }
}

private struct IpadEntityHero: View {
    let title: String
    let subtitle: String
    let avatarName: String
    let avatarURL: String?
    let systemImage: String
    let statusText: String
    let statusTint: Color
    let actionTitle: String
    let actionImage: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                AvatarBadge(
                    name: avatarName,
                    imageURL: avatarURL,
                    systemImage: systemImage,
                    diameter: 86,
                    statusColor: statusTint
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(3)

                    IpadStatusPill(text: statusText, tint: statusTint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: action) {
                    Label(actionTitle, systemImage: actionImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Color.rcmsAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: Color.rcmsAccent.opacity(0.24), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(24)
        .background(Color.rcmsSurfaceElevated.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct IpadDetailGrid<Content: View>: View {
    private let content: Content
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            content
        }
    }
}

private struct IpadDetailTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(.middle)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(16)
        .background(Color.rcmsSurface.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct IpadInfoPanel: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 16) {
                        Text(row.0)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.rcmsTextSecondary)
                            .frame(width: 120, alignment: .leading)

                        Text(row.1)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.rcmsTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 13)

                    if index != rows.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .background(Color.rcmsSurfaceElevated.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.rcmsHairline, lineWidth: 1)
        )
    }
}

private struct IpadCalloutPanel: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
                .frame(width: 36, height: 36)
                .background(Color.rcmsAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(Color.rcmsAccentSoft.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.rcmsAccent.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct IpadBotDetail: View {
    let bot: Bot
    let onStartChat: () -> Void

    private var isOnline: Bool {
        bot.status == "online"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IpadEntityHero(
                    title: bot.name,
                    subtitle: bot.description ?? L10n.t("机器人私聊", "Direct bot conversation"),
                    avatarName: bot.name,
                    avatarURL: bot.avatarUrl ?? bot.avatar,
                    systemImage: "cpu.fill",
                    statusText: isOnline ? L10n.t("机器人在线", "Online bot") : L10n.t("机器人离线", "Offline bot"),
                    statusTint: isOnline ? Color.rcmsOnline : Color.rcmsOffline,
                    actionTitle: L10n.t("开始聊天", "Start chat"),
                    actionImage: "paperplane.fill",
                    action: onStartChat
                )

                IpadDetailGrid {
                    IpadDetailTile(title: L10n.t("运行状态", "Runtime"), value: isOnline ? L10n.online : L10n.offline, systemImage: "bolt.horizontal.fill", tint: isOnline ? Color.rcmsOnline : Color.rcmsOffline)
                    IpadDetailTile(title: L10n.t("机器人类型", "Bot type"), value: bot.botType ?? L10n.bot, systemImage: "cpu.fill", tint: Color.rcmsAccent)
                    IpadDetailTile(title: L10n.t("主题", "Topic"), value: bot.mqttTopic ?? L10n.t("自动生成", "Generated"), systemImage: "point.3.connected.trianglepath.dotted", tint: Color.rcmsWarning)
                }

                IpadInfoPanel(
                    title: L10n.t("会话设置", "Conversation setup"),
                    rows: [
                        (L10n.t("描述", "Description"), bot.description ?? L10n.t("暂无描述", "No description")),
                        (L10n.t("MQTT 主题", "MQTT topic"), bot.mqttTopic ?? L10n.t("由用户和机器人 ID 自动生成", "Generated from user and bot IDs"))
                    ]
                )

                IpadCalloutPanel(
                    systemImage: "message.and.waveform.fill",
                    title: L10n.t("打开私聊工作区", "Open a direct workspace"),
                    message: L10n.t("聊天视图会保留机器人上下文，便于查看消息、图片、斜杠命令和实时回复。", "The chat view keeps this bot context available while you inspect messages, images, slash commands, and live replies.")
                )
            }
            .frame(maxWidth: IpadWorkspaceLayout.profileDetailMaxWidth, alignment: .leading)
            .padding(32)
        }
        .scrollIndicators(.hidden)
    }
}

private struct IpadGroupDetail: View {
    let group: ChatGroup
    let onOpenChat: () -> Void

    private var isActive: Bool {
        group.isActive == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                IpadEntityHero(
                    title: group.name,
                    subtitle: group.description ?? L10n.t("共享群组会话", "Shared group conversation"),
                    avatarName: group.name,
                    avatarURL: group.avatarUrl ?? group.avatar,
                    systemImage: "person.3.fill",
                    statusText: isActive ? L10n.botsOnline : L10n.botsOffline,
                    statusTint: isActive ? Color.rcmsOnline : Color.rcmsOffline,
                    actionTitle: L10n.t("打开聊天", "Open chat"),
                    actionImage: "bubble.left.and.bubble.right.fill",
                    action: onOpenChat
                )

                IpadDetailGrid {
                    IpadDetailTile(title: L10n.t("成员", "Members"), value: "\(group.memberCount ?? 0)", systemImage: "person.2.fill", tint: Color.rcmsAccent)
                    IpadDetailTile(title: L10n.t("机器人状态", "Bot presence"), value: isActive ? L10n.online : L10n.offline, systemImage: "cpu.fill", tint: isActive ? Color.rcmsOnline : Color.rcmsOffline)
                    IpadDetailTile(title: L10n.t("主题", "Topic"), value: group.mqttTopic == nil ? L10n.t("默认", "Default") : L10n.t("自定义", "Custom"), systemImage: "point.3.connected.trianglepath.dotted", tint: Color.rcmsWarning)
                }

                IpadInfoPanel(
                    title: L10n.t("群组资料", "Group profile"),
                    rows: [
                        (L10n.t("描述", "Description"), group.description ?? L10n.t("暂无描述", "No description")),
                        (L10n.t("MQTT 主题", "MQTT topic"), group.mqttTopic ?? "chat/group/\(group.id.uuidString.lowercased())")
                    ]
                )

                IpadCalloutPanel(
                    systemImage: "person.badge.gearshape.fill",
                    title: L10n.t("在聊天中管理房间", "Manage the room from chat"),
                    message: L10n.t("打开群聊即可查看成员、机器人参与、实时历史和当前房间状态。", "Open the group chat to inspect participants, bot participation, realtime history, and current room activity.")
                )
            }
            .frame(maxWidth: IpadWorkspaceLayout.profileDetailMaxWidth, alignment: .leading)
            .padding(32)
        }
        .scrollIndicators(.hidden)
    }
}

private struct IpadDirectoryHeader: View {
    let title: String
    let subtitle: String
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rcmsTextStrong)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct IpadSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcmsTextSecondary)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
        .padding(12)
        .background(Color.rcmsSurfaceMuted.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IpadMiniMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 4)
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.12), in: Circle())
            }

            Text(value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rcmsTextStrong)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(12)
        .glassCardStyle()
    }
}

private struct IpadStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct IpadInfoCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.0)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.rcmsTextSecondary)
                    Spacer(minLength: 16)
                    Text(row.1)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.rcmsTextPrimary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if index != rows.count - 1 {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .glassCardStyle()
    }
}

private struct IpadEmptyPanel: View {
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

private struct IpadLandingDetail: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
                .frame(width: 70, height: 70)
                .background(Color.rcmsAccent.opacity(0.12), in: Circle())

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
