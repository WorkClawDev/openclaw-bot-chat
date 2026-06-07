import SwiftUI
import Combine
import PhotosUI
import UIKit

@MainActor
class BotSettingsViewModel: ObservableObject {
    @Published var bot: Bot
    @Published var keys: [BotKeyResponse] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var newPlaintextKey: String? // To show when a key is newly generated
    
    private var cancellables = Set<AnyCancellable>()
    
    init(bot: Bot) {
        self.bot = bot
    }
    
    func fetchKeys() {
        isLoading = true
        APIClient.shared.fetchBotKeys(botID: bot.id)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (keys: [BotKeyResponse]) in
                self.keys = keys
            }
            .store(in: &cancellables)
    }
    
    func updateBot(name: String, description: String?, avatarURL: String?, onDone: @escaping () -> Void) {
        isLoading = true
        APIClient.shared.updateBot(id: bot.id, name: name, description: description, avatarURL: avatarURL)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (updatedBot: Bot) in
                self.bot = updatedBot
                onDone()
            }
            .store(in: &cancellables)
    }
    
    func deleteBot(onDone: @escaping () -> Void) {
        isLoading = true
        APIClient.shared.deleteBot(id: bot.id)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: APIClient.EmptyResponse) in
                onDone()
            }
            .store(in: &cancellables)
    }
    
    func createKey(name: String?) {
        isLoading = true
        APIClient.shared.createBotKey(botID: bot.id, name: name)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (response: BotKeyResponse) in
                self.newPlaintextKey = response.key // store plaintext to show to user
                self.fetchKeys()
            }
            .store(in: &cancellables)
    }
    
    func revokeKey(keyId: UUID) {
        isLoading = true
        APIClient.shared.revokeBotKey(botID: bot.id, keyID: keyId)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (_: APIClient.EmptyResponse) in
                self.fetchKeys()
            }
            .store(in: &cancellables)
    }
}

struct BotSettingsView: View {
    @StateObject private var viewModel: BotSettingsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var editName: String
    @State private var editDescription: String
    @State private var editAvatarURL: String
    @State private var isEditing = false
    @State private var isUploadingAvatar = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var pendingAvatarImage: PendingAvatarImage?
    @State private var showDeleteConfirm = false
    @State private var showNewKeyAlert = false
    @State private var newKeyName = ""
    
    var onBotUpdated: () -> Void
    
    init(bot: Bot, onBotUpdated: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: BotSettingsViewModel(bot: bot))
        _editName = State(initialValue: bot.name)
        _editDescription = State(initialValue: bot.description ?? "")
        _editAvatarURL = State(initialValue: bot.avatarUrl ?? bot.avatar ?? "")
        self.onBotUpdated = onBotUpdated
    }
    
    var body: some View {
        ZStack {
            FrostedBackground()
            
            ScrollView {
                VStack(spacing: 24) {
                    botInfoSection
                    keysSection
                    dangerZoneSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("机器人设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.fetchKeys()
        }
        .sheet(item: $pendingAvatarImage) { pending in
            AvatarCropperView(
                image: pending.image,
                title: "调整机器人头像",
                onCancel: {
                    pendingAvatarImage = nil
                },
                onConfirm: { croppedImage in
                    pendingAvatarImage = nil
                    Task { await uploadBotAvatarImage(croppedImage) }
                }
            )
        }
        .alert("保存失败", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("新增密钥", isPresented: $showNewKeyAlert) {
            TextField("密钥备注名称 (可选)", text: $newKeyName)
            Button("取消", role: .cancel) { }
            Button("生成") {
                viewModel.createKey(name: newKeyName)
                newKeyName = ""
            }
        }
        .alert("密钥已生成", isPresented: Binding(
            get: { viewModel.newPlaintextKey != nil },
            set: { _ in viewModel.newPlaintextKey = nil }
        )) {
            Button("复制并关闭") {
                if let key = viewModel.newPlaintextKey {
                    UIPasteboard.general.string = key
                }
                viewModel.newPlaintextKey = nil
            }
            Button("关闭", role: .cancel) { }
        } message: {
            Text("这是新生成的密钥：\n\(viewModel.newPlaintextKey ?? "")\n\n请立即复制保存，关闭后将无法再次查看！")
        }
    }
    
    private var botInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("基本信息")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.rcmsTextSecondary)
                Spacer()
                if isEditing {
                    Button("保存") {
                        let trimmedAvatarURL = editAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        viewModel.updateBot(name: editName, description: editDescription, avatarURL: trimmedAvatarURL) {
                            withAnimation { isEditing = false }
                            onBotUpdated()
                        }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.rcmsAccent)
                    .disabled(isUploadingAvatar || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("编辑") {
                        editName = viewModel.bot.name
                        editDescription = viewModel.bot.description ?? ""
                        editAvatarURL = viewModel.bot.avatarUrl ?? viewModel.bot.avatar ?? ""
                        withAnimation { isEditing = true }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.rcmsAccent)
                }
            }
            
            VStack(spacing: 0) {
                if isEditing {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            AvatarBadge(
                                name: editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? viewModel.bot.name : editName,
                                imageURL: normalizedEditAvatarURL,
                                systemImage: "cpu.fill",
                                diameter: 58,
                                statusColor: nil
                            )

                            VStack(alignment: .leading, spacing: 4) {
                                Text("机器人头像")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.rcmsTextPrimary)
                                Text(isUploadingAvatar ? "上传中" : "可拖动和缩放后上传")
                                    .font(.caption)
                                    .foregroundStyle(Color.rcmsTextSecondary)
                            }

                            Spacer()

                            PhotosPicker(selection: botAvatarSelection, matching: .images) {
                                if isUploadingAvatar {
                                    ProgressView()
                                        .tint(Color.rcmsAccent)
                                        .frame(width: 38, height: 38)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(Color.rcmsAccent)
                                        .frame(width: 38, height: 38)
                                        .background(Color.rcmsControlSurface)
                                        .clipShape(Circle())
                                }
                            }
                            .disabled(isUploadingAvatar || viewModel.isLoading)
                        }
                        .padding(12)
                        .background(Color.rcmsSubtleFill)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextField("机器人名称", text: $editName)
                            .padding(12)
                            .background(Color.rcmsFieldSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("一句话描述", text: $editDescription)
                            .padding(12)
                            .background(Color.rcmsFieldSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("头像 URL", text: $editAvatarURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(12)
                            .background(Color.rcmsFieldSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(16)
                } else {
                    HStack {
                        Text("头像")
                            .foregroundStyle(Color.rcmsTextSecondary)
                        Spacer()
                        AvatarBadge(
                            name: viewModel.bot.name,
                            imageURL: viewModel.bot.avatarUrl ?? viewModel.bot.avatar,
                            systemImage: "cpu.fill",
                            diameter: 42,
                            statusColor: nil
                        )
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    HStack {
                        Text("名称")
                            .foregroundStyle(Color.rcmsTextSecondary)
                        Spacer()
                        Text(viewModel.bot.name)
                            .foregroundStyle(Color.rcmsTextPrimary)
                    }
                    .padding(16)
                    
                    Divider().padding(.horizontal, 16)
                    
                    HStack {
                        Text("描述")
                            .foregroundStyle(Color.rcmsTextSecondary)
                        Spacer()
                        Text(viewModel.bot.description ?? "无")
                            .foregroundStyle(Color.rcmsTextPrimary)
                    }
                    .padding(16)
                    
                    Divider().padding(.horizontal, 16)
                    
                    HStack {
                        Text("状态")
                            .foregroundStyle(Color.rcmsTextSecondary)
                        Spacer()
                        Text(viewModel.bot.status == "online" ? "在线" : "离线")
                            .foregroundStyle(viewModel.bot.status == "online" ? Color.rcmsOnline : Color.rcmsTextSecondary)
                    }
                    .padding(16)
                }
            }
            .glassCardStyle()
        }
    }

    private var normalizedEditAvatarURL: String? {
        let trimmed = editAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var botAvatarSelection: Binding<PhotosPickerItem?> {
        Binding(
            get: { selectedAvatarItem },
            set: { item in
                selectedAvatarItem = item
                guard let item else { return }
                Task { await prepareBotAvatarCrop(from: item) }
            }
        )
    }

    private func prepareBotAvatarCrop(from item: PhotosPickerItem) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        viewModel.errorMessage = nil
        defer {
            isUploadingAvatar = false
            selectedAvatarItem = nil
        }

        do {
            pendingAvatarImage = PendingAvatarImage(image: try await AvatarUploadService.loadImage(from: item))
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func uploadBotAvatarImage(_ image: UIImage) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        viewModel.errorMessage = nil
        defer {
            isUploadingAvatar = false
        }

        do {
            let prefix = editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? viewModel.bot.name : editName
            editAvatarURL = try await AvatarUploadService.uploadAvatarImage(image, fileNamePrefix: prefix)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
    
    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("访问密钥 (Bot Keys)")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.rcmsTextSecondary)
                Spacer()
                Button("新增密钥") {
                    showNewKeyAlert = true
                }
                .font(.subheadline.bold())
                .foregroundStyle(Color.rcmsAccent)
            }
            
            if viewModel.keys.isEmpty {
                VStack {
                    Text("暂无访问密钥")
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .glassCardStyle()
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.keys) { key in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key.name ?? "未命名密钥")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.rcmsTextPrimary)
                                Text(key.keyPrefix + "...")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.rcmsTextSecondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.revokeKey(keyId: key.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Color.rcmsDanger)
                            }
                        }
                        .padding(16)
                        
                        if key.id != viewModel.keys.last?.id {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
                .glassCardStyle()
            }
        }
    }
    
    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("危险区域")
                .font(.subheadline.bold())
                .foregroundStyle(Color.rcmsDanger)
            
            Button {
                showDeleteConfirm = true
            } label: {
                HStack {
                    Text("删除机器人")
                        .font(.headline)
                        .foregroundStyle(Color.rcmsDanger)
                    Spacer()
                }
                .padding(16)
                .background(Color.rcmsDanger.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.rcmsDanger.opacity(0.3), lineWidth: 1))
            }
            .confirmationDialog("确定要删除此机器人吗？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    viewModel.deleteBot {
                        onBotUpdated()
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("删除后不可恢复，相关的聊天记录也会失效。")
            }
        }
    }
}
