import SwiftUI

struct ContactsView: View {
    @StateObject private var botsViewModel = BotsViewModel()
    @StateObject private var groupsViewModel = GroupsViewModel()
    @ObservedObject private var authManager = AuthManager.shared

    @State private var selectedSection: ContactSection = .bots
    @State private var searchText = ""

    private var filteredBots: [Bot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return botsViewModel.bots }
        return botsViewModel.bots.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var filteredGroups: [ChatGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groupsViewModel.groups }
        return groupsViewModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(spacing: 12) {
                    sectionPicker
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    searchBar
                        .padding(.horizontal, 16)

                    content
                }
            }
            .navigationTitle(L10n.t("通讯录", "Contacts"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                authManager.refreshCurrentUserIfNeeded()
                botsViewModel.refreshIfNeeded()
                groupsViewModel.refreshIfNeeded()
            }
            .refreshable {
                refreshCurrentSection(force: true)
            }
        }
    }

    private var sectionPicker: some View {
        Picker(L10n.t("联系人类型", "Contact type"), selection: $selectedSection) {
            ForEach(ContactSection.allCases) { section in
                Text(section.title).tag(section)
            }
        }
        .pickerStyle(.segmented)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcmsTextSecondary)
            TextField(selectedSection.searchPlaceholder, text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
        .padding(12)
        .background(Color.rcmsSurfaceMuted.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch selectedSection {
                case .bots:
                    botRows
                case .groups:
                    groupRows
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var botRows: some View {
        if botsViewModel.isLoading && botsViewModel.bots.isEmpty {
            ProgressView()
                .padding(.top, 32)
        } else if let error = botsViewModel.errorMessage, botsViewModel.bots.isEmpty {
            ContactsEmptyState(
                systemImage: "exclamationmark.triangle.fill",
                title: L10n.t("机器人加载失败", "Could not load bots"),
                message: error
            )
        } else if filteredBots.isEmpty {
            ContactsEmptyState(
                systemImage: "cpu",
                title: searchText.isEmpty ? L10n.t("还没有机器人", "No bots yet") : L10n.t("没有匹配机器人", "No matching bots"),
                message: searchText.isEmpty ? L10n.t("从首页右上角添加机器人后，可以在这里开始单聊。", "Add a bot from the home screen, then start direct chats here.") : L10n.t("换个关键词试试。", "Try another keyword.")
            )
        } else {
            ForEach(filteredBots) { bot in
                if let topic = conversationTopic(for: bot) {
                    NavigationLink {
                        ChatRoomView(context: .init(
                            id: topic,
                            title: bot.name,
                            subtitle: bot.status == "online" ? L10n.online : L10n.offline,
                            isGroup: false,
                            groupId: nil,
                            bot: bot,
                            avatarURLString: bot.avatarUrl ?? bot.avatar
                        ))
                    } label: {
                        BotRowCard(bot: bot)
                    }
                    .buttonStyle(.plain)
                } else {
                    BotRowCard(bot: bot)
                        .opacity(0.6)
                }
            }
        }
    }

    @ViewBuilder
    private var groupRows: some View {
        if groupsViewModel.isLoading && groupsViewModel.groups.isEmpty {
            ProgressView()
                .padding(.top, 32)
        } else if let error = groupsViewModel.errorMessage, groupsViewModel.groups.isEmpty {
            ContactsEmptyState(
                systemImage: "exclamationmark.triangle.fill",
                title: L10n.t("群组加载失败", "Could not load groups"),
                message: error
            )
        } else if filteredGroups.isEmpty {
            ContactsEmptyState(
                systemImage: "person.3",
                title: searchText.isEmpty ? L10n.t("还没有群组", "No groups yet") : L10n.t("没有匹配群组", "No matching groups"),
                message: searchText.isEmpty ? L10n.t("有群组后会出现在这里。", "Groups will appear here.") : L10n.t("换个关键词试试。", "Try another keyword.")
            )
        } else {
            ForEach(filteredGroups) { group in
                NavigationLink {
                    ChatRoomView(context: .init(
                        id: conversationTopic(for: group),
                        title: group.name,
                        subtitle: (group.isActive == true) ? L10n.botsOnline : L10n.botsOffline,
                        isGroup: true,
                        groupId: group.id.uuidString.lowercased(),
                        memberCount: group.memberCount,
                        avatarURLString: group.avatarUrl ?? group.avatar
                    ))
                } label: {
                    GroupRowCard(group: group)
                }
                .buttonStyle(.plain)
            }
        }
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

    private func conversationTopic(for group: ChatGroup) -> String {
        if let mqttTopic = group.mqttTopic, !mqttTopic.isEmpty {
            return mqttTopic
        }
        return "chat/group/\(group.id.uuidString.lowercased())"
    }

    private func refreshCurrentSection(force: Bool) {
        switch selectedSection {
        case .bots:
            botsViewModel.refreshIfNeeded(force: force)
        case .groups:
            groupsViewModel.refreshIfNeeded(force: force)
        }
    }

}

private enum ContactSection: String, CaseIterable, Identifiable {
    case bots
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bots:
            return L10n.t("机器人", "Bots")
        case .groups:
            return L10n.t("群组", "Groups")
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .bots:
            return L10n.t("搜索机器人", "Search bots")
        case .groups:
            return L10n.t("搜索群组", "Search groups")
        }
    }
}

private struct ContactsEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.rcmsAccent)
                .frame(width: 48, height: 48)
                .background(Color.rcmsAccent.opacity(0.12), in: Circle())
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.rcmsTextStrong)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 56)
    }
}
