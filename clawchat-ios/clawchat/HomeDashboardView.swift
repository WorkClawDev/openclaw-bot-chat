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

        let botsRequest = APIClient.shared.fetchBots()
        let groupsRequest = APIClient.shared.fetchGroups()
        let conversationsRequest = APIClient.shared.fetchConversations()

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

    func createBot(name: String, description: String?, onDone: @escaping () -> Void) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        errorMessage = nil
        APIClient.shared.createBot(
            name: trimmedName,
            description: trimmedDescription?.isEmpty == true ? nil : trimmedDescription,
            avatarURL: nil
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            if case .failure(let error) = completion {
                self?.errorMessage = error.localizedDescription
            }
        } receiveValue: { [weak self] (_: Bot) in
            self?.refreshIfNeeded(force: true)
            onDone()
        }
        .store(in: &cancellables)
    }

    func createGroup(name: String, description: String?, onDone: @escaping () -> Void) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        errorMessage = nil
        APIClient.shared.createGroup(
            name: trimmedName,
            description: trimmedDescription?.isEmpty == true ? nil : trimmedDescription
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] completion in
            if case .failure(let error) = completion {
                self?.errorMessage = error.localizedDescription
            }
        } receiveValue: { [weak self] (_: ChatGroup) in
            self?.refreshIfNeeded(force: true)
            onDone()
        }
        .store(in: &cancellables)
    }

    func confirmBotBinding(token: String, backendURL: URL?, onSuccess: @escaping (Bot) -> Void, onFailure: @escaping (String) -> Void) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            onFailure(L10n.t("绑定 token 为空。", "Binding token is empty."))
            return
        }

        errorMessage = nil
        APIClient.shared.confirmBotBinding(token: trimmedToken, backendURL: backendURL)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    onFailure(error.localizedDescription)
                }
            } receiveValue: { [weak self] response in
                guard let bot = response.bot else {
                    onFailure(L10n.t("服务端没有返回机器人信息。", "The server did not return bot information."))
                    return
                }
                LocalMessageStore.shared.upsert(bots: [bot])
                self?.refreshIfNeeded(force: true)
                onSuccess(bot)
            }
            .store(in: &cancellables)
    }

    func botName(matching id: UUID) -> String? {
        bots.first { $0.id == id }?.name
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
    @State private var showingCreateBot = false
    @State private var showingCreateGroup = false
    @State private var showingScanner = false
    @State private var newBotName = ""
    @State private var newBotDescription = ""
    @State private var newGroupName = ""
    @State private var newGroupDescription = ""
    @State private var scanNotice: ScanNotice?

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
            .sheet(isPresented: $showingCreateBot) {
                createBotSheet
            }
            .sheet(isPresented: $showingCreateGroup) {
                createGroupSheet
            }
            .sheet(isPresented: $showingScanner) {
                BotBindingScannerSheet { scannedValue in
                    handleScannedBinding(scannedValue)
                }
            }
            .alert(item: $scanNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(L10n.t("确定", "OK")))
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AvatarBadge(
                name: authManager.currentUser?.nickname ?? authManager.currentUser?.username ?? L10n.user,
                imageURL: authManager.currentUser?.avatarUrl ?? authManager.currentUser?.avatar,
                diameter: 50,
                statusColor: nil
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("消息", "Messages"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rcmsTextStrong)

                Text(L10n.t("欢迎回来", "Welcome back"))
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
            }

            Spacer()

            Menu {
                Button {
                    showingScanner = true
                } label: {
                    Label(L10n.t("扫描添加机器人", "Scan to add bot"), systemImage: "qrcode.viewfinder")
                }

                Button {
                    showingCreateBot = true
                } label: {
                    Label(L10n.t("创建机器人", "Create bot"), systemImage: "cpu")
                }

                Button {
                    showingCreateGroup = true
                } label: {
                    Label(L10n.t("创建群组", "Create group"), systemImage: "person.3")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Color.rcmsAccent)
                    .frame(width: 50, height: 50)
                    .background(Color.rcmsAccentSoft.opacity(0.95), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.t("添加", "Add"))
        }
        .frame(maxWidth: .infinity)
    }

    private var createBotSheet: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("机器人名称", "Bot name"), text: $newBotName)
                TextField(L10n.t("描述", "Description"), text: $newBotDescription)
            }
            .navigationTitle(L10n.t("创建机器人", "Create bot"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) {
                        resetCreateBotForm()
                        showingCreateBot = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建", "Create")) {
                        viewModel.createBot(name: newBotName, description: newBotDescription) {
                            resetCreateBotForm()
                            showingCreateBot = false
                        }
                    }
                    .disabled(newBotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var createGroupSheet: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("群组名称", "Group name"), text: $newGroupName)
                TextField(L10n.t("描述", "Description"), text: $newGroupDescription)
            }
            .navigationTitle(L10n.t("创建群组", "Create group"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) {
                        resetCreateGroupForm()
                        showingCreateGroup = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建", "Create")) {
                        viewModel.createGroup(name: newGroupName, description: newGroupDescription) {
                            resetCreateGroupForm()
                            showingCreateGroup = false
                        }
                    }
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func resetCreateBotForm() {
        newBotName = ""
        newBotDescription = ""
    }

    private func resetCreateGroupForm() {
        newGroupName = ""
        newGroupDescription = ""
    }

    private func handleScannedBinding(_ rawValue: String) {
        showingScanner = false
        let result = BotBindingQRCodeParser.parse(rawValue)
        switch result {
        case .bindingToken(let token, let backendURL):
            viewModel.confirmBotBinding(token: token, backendURL: backendURL) { bot in
                presentScanNotice(ScanNotice(
                    title: L10n.t("机器人已添加", "Bot added"),
                    message: L10n.t("已添加「\(bot.name)」，可以在通讯录或聊天中使用。", "Added \"\(bot.name)\". You can use it from Contacts or Chats.")
                ))
            } onFailure: { message in
                presentScanNotice(ScanNotice(
                    title: L10n.t("添加失败", "Add failed"),
                    message: message
                ))
            }
        case .bot(let botID, let backendURL):
            if let botName = viewModel.botName(matching: botID) {
                presentScanNotice(ScanNotice(
                    title: L10n.t("已识别机器人", "Bot found"),
                    message: L10n.t("已找到机器人「\(botName)」。", "Found bot \"\(botName)\".")
                ))
            } else {
                let backendText = backendURL?.absoluteString ?? APIClient.shared.baseURL.absoluteString
                presentScanNotice(ScanNotice(
                    title: L10n.t("已识别绑定二维码", "Binding QR recognized"),
                    message: L10n.t(
                        "机器人 ID：\(botID.uuidString)\n服务地址：\(backendText)\n如果这是新机器人，请先在服务端完成绑定后刷新首页。",
                        "Bot ID: \(botID.uuidString)\nBackend: \(backendText)\nIf this is a new bot, finish binding on the server, then refresh Home."
                    )
                ))
            }
        case .extensionInstall:
            presentScanNotice(ScanNotice(
                title: L10n.t("扩展安装二维码", "Extension install QR"),
                message: L10n.t("这是 OpenClaw BotChat 扩展安装二维码，不包含机器人密钥。请安装扩展后使用带 botId 的绑定二维码。", "This installs the OpenClaw BotChat extension and does not include a bot key. After installing the extension, use a binding QR that includes botId.")
            ))
        case .unsupported:
            presentScanNotice(ScanNotice(
                title: L10n.t("无法识别二维码", "Unsupported QR code"),
                message: L10n.t("请扫描 OpenClaw BotChat 的安装或绑定二维码。", "Scan an OpenClaw BotChat install or binding QR code.")
            ))
        }
    }

    private func presentScanNotice(_ notice: ScanNotice) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scanNotice = notice
        }
    }

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("聊天", "Chats"))
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
                    title: L10n.t("首页暂时不可用", "Dashboard unavailable"),
                    message: errorMessage
                )
            } else if viewModel.recentConversations.isEmpty {
                HomeEmptyState(
                    systemImage: "bubble.left.and.bubble.right",
                    title: L10n.t("还没有会话", "No conversations yet"),
                    message: L10n.t("从通讯录开始聊天。", "Start a chat from Contacts.")
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentConversations) { conversation in
                        NavigationLink {
                            ChatRoomView(context: chatContext(for: conversation))
                        } label: {
                            DashboardConversationRow(
                                title: conversationTitle(for: conversation),
                                subtitle: conversation.lastMessage?.content ?? L10n.noMessagesYet,
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
                    subtitle: (group.isActive == true) ? L10n.botsOnline : L10n.botsOffline,
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
                subtitle: L10n.groupChat,
                isGroup: true,
                groupId: groupId,
                avatarURLString: conversation.avatar
            )

        default:
            if let bot = matchingBot(for: conversation) {
                return ChatContext(
                    id: conversationTopic(for: bot) ?? conversation.id,
                    title: bot.name,
                    subtitle: bot.status == "online" ? L10n.online : L10n.offline,
                    isGroup: false,
                    groupId: nil,
                    bot: bot,
                    avatarURLString: bot.avatarUrl ?? bot.avatar
                )
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
