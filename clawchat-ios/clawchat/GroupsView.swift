import SwiftUI
import Combine

class GroupsViewModel: ObservableObject {
    @Published var groups: [ChatGroup] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let refreshInterval: TimeInterval = 45
    private var cancellables = Set<AnyCancellable>()
    private var hasHydratedCache = false
    private var hasLoaded = false
    private var lastRefreshAt: Date?

    func refreshIfNeeded(force: Bool = false) {
        if isLoading {
            return
        }

        if !force {
            hydrateCachedGroupsIfNeeded()
        }

        if !force, hasLoaded, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < refreshInterval {
            return
        }

        fetchGroups()
    }

    private func fetchGroups() {
        isLoading = true
        errorMessage = nil
        APIClient.shared.fetchGroups()
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (groups: [ChatGroup]) in
                LocalMessageStore.shared.upsert(groups: groups)
                self.groups = groups
                self.hasHydratedCache = true
                self.hasLoaded = true
                self.lastRefreshAt = Date()
            }
            .store(in: &cancellables)
    }

    private func hydrateCachedGroupsIfNeeded() {
        guard !hasHydratedCache else { return }

        let cachedGroups = LocalMessageStore.shared.cachedGroups()
        if !cachedGroups.isEmpty {
            groups = cachedGroups
        }
        hasHydratedCache = true
    }

    func createGroup(name: String, description: String?, onDone: @escaping () -> Void) {
        APIClient.shared.createGroup(name: name, description: description)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: ChatGroup) in
                self.refreshIfNeeded(force: true)
                onDone()
            }
            .store(in: &cancellables)
    }
}

struct GroupsView: View {
    @StateObject private var viewModel = GroupsViewModel()
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var searchText = ""

    private var filteredGroups: [ChatGroup] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.groups
        }

        return viewModel.groups.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func conversationTopic(for group: ChatGroup) -> String {
        if let mqttTopic = group.mqttTopic, !mqttTopic.isEmpty {
            return mqttTopic
        }
        return "chat/group/\(group.id.uuidString.lowercased())"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(spacing: 0) {
                        searchBar
                            .padding(.top, 8)
                            .padding(.bottom, 10)

                        if viewModel.isLoading && viewModel.groups.isEmpty {
                            ProgressView()
                                .padding(.top, 32)
                        }

                        ForEach(filteredGroups) { group in
                            NavigationLink {
                                ChatRoomView(context: .init(
                                    id: conversationTopic(for: group),
                                    title: group.name,
                                    subtitle: (group.isActive == true) ? "bots online" : "bots offline",
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(L10n.t("群组", "Groups"))
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.rcmsAccent)
                }
            }
            .onAppear { viewModel.refreshIfNeeded() }
            .refreshable { viewModel.refreshIfNeeded(force: true) }
            .sheet(isPresented: $showingCreate) {
                createGroupSheet
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcmsTextSecondary)
            TextField(L10n.t("搜索群组", "Search groups"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
        .padding(12)
        .background(Color.rcmsSurfaceMuted.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var createGroupSheet: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("群组名称", "Group name"), text: $newName)
                TextField(L10n.t("描述", "Description"), text: $newDescription)
            }
            .navigationTitle(L10n.t("创建群组", "Create group"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) { showingCreate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建", "Create")) {
                        viewModel.createGroup(name: newName, description: newDescription) {
                            newName = ""
                            newDescription = ""
                            showingCreate = false
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct GroupRowCard: View {
    let group: ChatGroup

    var body: some View {
        HStack(spacing: 12) {
            AvatarBadge(
                name: group.name,
                imageURL: group.avatarUrl ?? group.avatar,
                systemImage: "person.3.fill",
                diameter: 52,
                statusColor: (group.isActive == true) ? Color.rcmsOnline : Color.rcmsOffline
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.rcmsTextStrong)

                Text(group.description ?? "暂无消息")
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(minHeight: 74)
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.rcmsSurface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.rcmsDivider)
                .frame(height: 1)
        }
    }
}
