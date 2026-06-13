import SwiftUI
import Combine
import PhotosUI
import UIKit

class BotsViewModel: ObservableObject {
    @Published var bots: [Bot] = []
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
            hydrateCachedBotsIfNeeded()
        }

        if !force, hasLoaded, let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < refreshInterval {
            return
        }

        fetchBots()
    }

    private func fetchBots() {
        isLoading = true
        errorMessage = nil
        APIClient.shared.fetchBots()
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (bots: [Bot]) in
                LocalMessageStore.shared.upsert(bots: bots)
                self.bots = bots
                self.hasHydratedCache = true
                self.hasLoaded = true
                self.lastRefreshAt = Date()
            }
            .store(in: &cancellables)
    }

    private func hydrateCachedBotsIfNeeded() {
        guard !hasHydratedCache else { return }

        let cachedBots = LocalMessageStore.shared.cachedBots()
        if !cachedBots.isEmpty {
            bots = cachedBots
        }
        hasHydratedCache = true
    }

    func createBot(name: String, description: String?, avatarURL: String?, onDone: @escaping () -> Void) {
        APIClient.shared.createBot(name: name, description: description, avatarURL: avatarURL)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: Bot) in
                self.refreshIfNeeded(force: true)
                onDone()
            }
            .store(in: &cancellables)
    }
}

struct BotsView: View {
    @StateObject private var viewModel = BotsViewModel()
    @ObservedObject private var authManager = AuthManager.shared
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var newAvatarURL = ""
    @State private var newAvatarItem: PhotosPickerItem?
    @State private var pendingNewAvatarImage: PendingAvatarImage?
    @State private var isUploadingAvatar = false
    @State private var createErrorMessage: String?
    @State private var searchText = ""

    private var filteredBots: [Bot] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.bots
        }

        return viewModel.bots.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
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

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(spacing: 0) {
                        searchBar
                            .padding(.top, 8)
                            .padding(.bottom, 10)

                        if viewModel.isLoading && viewModel.bots.isEmpty {
                            ProgressView()
                                .padding(.top, 32)
                        }

                        ForEach(filteredBots) { bot in
                            if let topic = conversationTopic(for: bot) {
                                NavigationLink {
                                    ChatRoomView(context: .init(
                                        id: topic,
                                        title: bot.name,
                                        subtitle: bot.status == "online" ? "online" : "offline",
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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(L10n.t("机器人", "Bots"))
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
            .onAppear {
                authManager.refreshCurrentUserIfNeeded()
                viewModel.refreshIfNeeded()
            }
            .refreshable { viewModel.refreshIfNeeded(force: true) }
            .sheet(isPresented: $showingCreate) {
                createBotSheet
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.rcmsTextSecondary)
            TextField(L10n.t("搜索机器人", "Search bots"), text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
        .padding(12)
        .background(Color.rcmsSurfaceMuted.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var createBotSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AvatarBadge(
                            name: newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bot" : newName,
                            imageURL: normalizedNewAvatarURL,
                            systemImage: "cpu.fill",
                            diameter: 58,
                            statusColor: nil
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("机器人头像", "Bot avatar"))
                                .font(.subheadline.weight(.semibold))
                            Text(isUploadingAvatar ? L10n.t("上传中", "Uploading") : L10n.t("上传前可拖动和缩放", "Drag and zoom before uploading"))
                                .font(.caption)
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }

                        Spacer()

                        PhotosPicker(selection: newBotAvatarSelection, matching: .images) {
                            if isUploadingAvatar {
                                ProgressView()
                                    .tint(Color.rcmsAccent)
                                    .frame(width: 38, height: 38)
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.rcmsAccent)
                                    .frame(width: 38, height: 38)
                            }
                        }
                        .disabled(isUploadingAvatar)
                        .accessibilityLabel(L10n.t("选择机器人头像", "Choose bot avatar"))
                    }

                    TextField(L10n.t("头像链接", "Avatar URL"), text: $newAvatarURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if let createErrorMessage {
                        Text(createErrorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.rcmsDanger)
                    }
                }

                TextField(L10n.t("机器人名称", "Bot name"), text: $newName)
                TextField(L10n.t("描述", "Description"), text: $newDescription)
            }
            .navigationTitle(L10n.t("创建机器人", "Create bot"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("取消", "Cancel")) {
                        resetCreateForm()
                        showingCreate = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("创建", "Create")) {
                        viewModel.createBot(name: newName, description: newDescription, avatarURL: normalizedNewAvatarURL) {
                            resetCreateForm()
                            showingCreate = false
                        }
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUploadingAvatar)
                }
            }
            .sheet(item: $pendingNewAvatarImage) { pending in
                AvatarCropperView(
                    image: pending.image,
                    title: L10n.t("调整机器人头像", "Adjust bot avatar"),
                    onCancel: {
                        pendingNewAvatarImage = nil
                    },
                    onConfirm: { croppedImage in
                        pendingNewAvatarImage = nil
                        Task { await uploadNewBotAvatarImage(croppedImage) }
                    }
                )
            }
        }
        .presentationDetents([.medium])
    }

    private var normalizedNewAvatarURL: String? {
        let trimmed = newAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var newBotAvatarSelection: Binding<PhotosPickerItem?> {
        Binding(
            get: { newAvatarItem },
            set: { item in
                newAvatarItem = item
                guard let item else { return }
                Task { await prepareNewBotAvatarCrop(from: item) }
            }
        )
    }

    private func prepareNewBotAvatarCrop(from item: PhotosPickerItem) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        createErrorMessage = nil
        defer {
            isUploadingAvatar = false
            newAvatarItem = nil
        }

        do {
            pendingNewAvatarImage = PendingAvatarImage(image: try await AvatarUploadService.loadImage(from: item))
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }

    private func uploadNewBotAvatarImage(_ image: UIImage) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        createErrorMessage = nil
        defer {
            isUploadingAvatar = false
        }

        do {
            let prefix = newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "bot" : newName
            newAvatarURL = try await AvatarUploadService.uploadAvatarImage(image, fileNamePrefix: prefix)
        } catch {
            createErrorMessage = error.localizedDescription
        }
    }

    private func resetCreateForm() {
        newName = ""
        newDescription = ""
        newAvatarURL = ""
        newAvatarItem = nil
        pendingNewAvatarImage = nil
        createErrorMessage = nil
    }
}

struct BotRowCard: View {
    let bot: Bot

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AvatarBadge(
                    name: bot.name,
                    imageURL: bot.avatarUrl ?? bot.avatar,
                    systemImage: "cpu.fill",
                    diameter: 52,
                    statusColor: nil
                )

                Circle()
                    .fill((bot.status == "online") ? Color.rcmsOnline : Color.rcmsOffline)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.rcmsSurfaceSolid, lineWidth: 2.5))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(bot.name)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.rcmsTextStrong)

                Text(bot.description ?? "暂无消息")
                    .font(.subheadline)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .contentShape(Rectangle())
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
