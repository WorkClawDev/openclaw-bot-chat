import SwiftUI
import Combine
import UserNotifications
import PhotosUI
import UIKit

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var currentUser: User?
    @Published var isLoading = false
    @Published var isSavingProfile = false
    @Published var isChangingPassword = false
    @Published var loadErrorMessage: String?

    init(previewUser: User? = nil) {
        self.currentUser = previewUser ?? AuthManager.shared.currentUser
    }

    func fetchProfile() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let user = try await APIClient.shared.fetchCurrentUserValue()
            currentUser = user
            AuthManager.shared.currentUser = user
            loadErrorMessage = nil
        } catch {
            loadErrorMessage = Self.message(from: error)
        }
    }

    func updateProfile(nickname: String, avatarURL: String) async throws -> User {
        isSavingProfile = true
        defer { isSavingProfile = false }

        let user = try await APIClient.shared.updateProfile(nickname: nickname, avatarURL: avatarURL)

        currentUser = user
        AuthManager.shared.currentUser = user
        loadErrorMessage = nil
        return user
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        isChangingPassword = true
        defer { isChangingPassword = false }

        try await APIClient.shared.changePassword(currentPassword: currentPassword, newPassword: newPassword)
    }

    static func message(from error: Error) -> String {
        if let apiError = error as? APIClient.APIError {
            switch apiError {
            case .invalidURL:
                return "Invalid server URL"
            case .noData:
                return "The server returned no usable data"
            case .decodingError:
                return "Failed to parse server data"
            case .serverError(let message):
                return message
            case .unauthorized:
                return "Your session expired. Please sign in again"
            case .networkError(let error):
                return "Network connection failed: \(error.localizedDescription)"
            }
        }

        return error.localizedDescription
    }
}

struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var realtimeService = RealtimeService.shared
    private let loadsProfileOnAppear: Bool

    @AppStorage("settings.botNotificationsEnabled") private var botNotificationsEnabled = false
    @AppStorage("settings.compactMessageMode") private var compactMessageMode = false
    @AppStorage("settings.imageUploadQuality") private var imageUploadQuality = "Compressed"
    @AppStorage("settings.appearanceMode") private var appearanceModeRawValue = AppAppearanceMode.system.rawValue

    @State private var didInitialLoad = false
    @State private var isEditingProfile = false
    @State private var nicknameDraft = ""
    @State private var avatarURLDraft = ""
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var pendingAvatarImage: PendingAvatarImage?
    @State private var isUploadingAvatar = false
    @State private var profileErrorMessage: String?

    @State private var showPasswordEditor = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordErrorMessage: String?

    @State private var showDeviceDetails = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var toast: SettingsToastPayload?

    @FocusState private var focusNicknameField: Bool

    init(previewUser: User? = nil) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(previewUser: previewUser))
        loadsProfileOnAppear = previewUser == nil
    }

    private var resolvedUser: User? {
        viewModel.currentUser ?? authManager.currentUser
    }

    private var hasNotificationPermission: Bool {
        notificationAuthorizationStatus == .authorized || notificationAuthorizationStatus == .provisional
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FrostedBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let user = resolvedUser {
                            settingsHeader

                            profileHeader(user: user)

                            sectionHeader(title: "Account")
                            accountCard(user: user)

                            sectionHeader(title: "Appearance")
                            appearanceCard

                            sectionHeader(title: "Messaging")
                            messagingCard

                            sectionHeader(title: "System")
                            systemCard

                            sectionHeader(title: "About")
                            aboutCard

                            logoutButton
                        } else if viewModel.isLoading {
                            loadingIndicator
                        } else {
                            loadingIndicator
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .refreshable {
                    await refreshAll()
                }

                if let toast {
                    toastView(toast)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if loadsProfileOnAppear {
                    await initialLoadIfNeeded()
                } else {
                    syncProfileDraftsIfNeeded()
                    await refreshNotificationAuthorization()
                }
            }
            .onChange(of: resolvedUser?.id) { _, _ in
                syncProfileDraftsIfNeeded()
            }
            .sheet(item: $pendingAvatarImage) { pending in
                AvatarCropperView(
                    image: pending.image,
                    title: "调整头像",
                    onCancel: {
                        pendingAvatarImage = nil
                    },
                    onConfirm: { croppedImage in
                        pendingAvatarImage = nil
                        Task { await uploadProfileAvatarImage(croppedImage) }
                    }
                )
            }
            .alert(
                "Profile failed to load",
                isPresented: Binding(
                    get: { viewModel.loadErrorMessage != nil },
                    set: { _ in viewModel.loadErrorMessage = nil }
                ),
                actions: {
                    Button("OK", role: .cancel) {}
                },
                message: {
                    Text(viewModel.loadErrorMessage ?? "")
                }
            )
        }
    }

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.rcmsAccent)
            Text("Loading your profile")
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.rcmsTextSecondary)
            .padding(.leading, 4)
            .padding(.bottom, -8)
    }

    private var settingsHeader: some View {
        Text("Settings")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(Color.rcmsTextStrong)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func profileHeader(user: User) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                ProfileAvatarView(
                    name: isEditingProfile ? effectiveDraftName(for: user) : displayName(for: user),
                    imageURL: isEditingProfile ? normalizedAvatarDraft : avatarURL(for: user),
                    diameter: 76
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName(for: user))
                        .font(.title2.bold())
                        .foregroundStyle(Color.rcmsTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                    
                    Text("@\(user.username)")
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(user.email)
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        if isEditingProfile {
                            cancelProfileEditing()
                        } else {
                            startProfileEditing(using: user)
                        }
                    }
                } label: {
                    Text(isEditingProfile ? "Cancel" : "Edit")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.rcmsAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.rcmsControlSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.rcmsAccent.opacity(0.55), lineWidth: 1)
                        )
                }
                .fixedSize()
            }

            if isEditingProfile {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        ProfileAvatarView(
                            name: effectiveDraftName(for: user),
                            imageURL: normalizedAvatarDraft,
                            diameter: 58
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Profile photo")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.rcmsTextPrimary)
                            Text(isUploadingAvatar ? "Uploading" : "Drag and zoom before uploading")
                                .font(.caption)
                                .foregroundStyle(Color.rcmsTextSecondary)
                        }

                        Spacer()

                        PhotosPicker(selection: profileAvatarSelection, matching: .images) {
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
                        .disabled(isUploadingAvatar || viewModel.isSavingProfile)
                    }
                    .padding(12)
                    .background(Color.rcmsSubtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    editField(title: "Display name", placeholder: "Add a display name", text: $nicknameDraft)
                        .focused($focusNicknameField)
                    
                    editField(title: "Avatar URL", placeholder: "HTTPS image link", text: $avatarURLDraft)

                    if let profileErrorMessage {
                        Text(profileErrorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.rcmsDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await saveProfileChanges(for: user) }
                    } label: {
                        if viewModel.isSavingProfile {
                            ProgressView().tint(.white)
                        } else {
                            Text("Save profile")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.rcmsAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(viewModel.isSavingProfile || isUploadingAvatar)
                }
                .padding(16)
                .background(Color.rcmsSubtleFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .padding(16)
        .glassCardStyle()
    }

    private func editField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(Color.rcmsTextSecondary)
            
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(UITheme.subtleStroke, lineWidth: 1))
        }
    }

    private func accountCard(user: User) -> some View {
        VStack(spacing: 0) {
            actionRow(title: "Profile", subtitle: "", value: "", icon: "person") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    startProfileEditing(using: user)
                }
            }
            divider
            actionRow(title: "Password", subtitle: "", value: "", icon: "lock") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showPasswordEditor.toggle()
                }
            }

            if showPasswordEditor {
                passwordEditor
                    .padding([.horizontal, .bottom], 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            divider

            actionRow(title: "Devices", subtitle: "", value: "", icon: "iphone") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showDeviceDetails.toggle()
                }
            }

            if showDeviceDetails {
                deviceInfo
                    .padding([.horizontal, .bottom], 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCardStyle()
    }

    private var passwordEditor: some View {
        VStack(spacing: 12) {
            SecureField("Current password", text: $currentPassword)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            SecureField("New password (at least 8 characters)", text: $newPassword)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            SecureField("Confirm new password", text: $confirmPassword)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            if let passwordErrorMessage {
                Text(passwordErrorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await submitPasswordChange() }
            } label: {
                if viewModel.isChangingPassword {
                    ProgressView().tint(.white)
                } else {
                    Text("Update password").bold()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.rcmsAccent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(viewModel.isChangingPassword)
        }
        .padding(12)
        .background(Color.rcmsSubtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                    .font(.title3)
                    .foregroundStyle(Color.rcmsAccent)
                
                VStack(alignment: .leading) {
                    Text(UIDevice.current.name)
                        .font(.subheadline.bold())
                    Text("iOS \(UIDevice.current.systemVersion) · Current device")
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }
                Spacer()
                Text("Online").font(.caption.bold()).foregroundStyle(Color.rcmsOnline)
            }
        }
        .padding(12)
        .background(Color.rcmsSubtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                rowIcon(appearanceMode.systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deep night mode")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.rcmsTextPrimary)
                    Text(appearanceMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Picker("Appearance", selection: $appearanceModeRawValue) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .glassCardStyle()
    }

    private var messagingCard: some View {
        VStack(spacing: 0) {
            preferenceRow(title: "Bot notifications", subtitle: notificationSubtitle, icon: "bell.badge") {
                Toggle("", isOn: Binding(
                    get: { botNotificationsEnabled },
                    set: { newValue in
                        Task { await updateNotifications(enabled: newValue) }
                    }
                ))
                .labelsHidden()
                .tint(Color.rcmsAccent)
            }
            divider
            preferenceRow(title: "Compact message mode", subtitle: compactMessageMode ? "Compact" : "Comfort", icon: "text.alignleft") {
                Toggle("", isOn: $compactMessageMode)
                    .labelsHidden()
                    .tint(Color.rcmsAccent)
            }
            divider
            preferenceRow(title: "Image upload quality", subtitle: imageUploadQualitySubtitle, icon: "photo.on.rectangle") {
                Picker("Image upload quality", selection: $imageUploadQuality) {
                    ForEach(Self.imageUploadQualityOptions, id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.rcmsAccent)
            }
        }
        .glassCardStyle()
    }

    private var systemCard: some View {
        VStack(spacing: 0) {
            infoRow(title: "Realtime connection", value: realtimeConnectionText, icon: realtimeConnectionIcon)
            divider
            infoRow(title: "API endpoint", value: APIClient.shared.baseURL.absoluteString, icon: "network", isMonospaced: true, copyString: APIClient.shared.baseURL.absoluteString)
        }
        .glassCardStyle()
    }

    private var aboutCard: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.rcmsHairline, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("ClawChat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextPrimary)
                    .lineLimit(1)

                Text(appVersionText)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)
        }
        .padding(16)
        .glassCardStyle()
    }

    private var logoutButton: some View {
        Button {
            authManager.logout()
        } label: {
            HStack {
                Text("Log out")
                    .font(.headline)
                    .foregroundStyle(Self.coralDanger)
                Spacer()
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(Self.coralDanger)
            }
            .padding(18)
            .background(Self.coralDanger.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Self.coralDanger.opacity(0.22), lineWidth: 1)
            )
        }
        .padding(.top, 12)
    }

    private func infoRow(title: String, value: String, icon: String, isMonospaced: Bool = false, copyString: String? = nil) -> some View {
        HStack {
            rowIcon(icon)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.rcmsTextPrimary)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .fontDesign(isMonospaced ? .monospaced : .default)
                    .foregroundStyle(Color.rcmsTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if let copyString {
                    Button {
                        UIPasteboard.general.string = copyString
                        presentToast("Copied to clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Color.rcmsAccent)
                    }
                }
            }
        }
        .padding(16)
    }

    private func actionRow(title: String, subtitle: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                rowIcon(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.rcmsTextPrimary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.rcmsTextSecondary)
                    }
                }
                Spacer()
                if !value.isEmpty {
                    Text(value)
                        .font(.caption.bold())
                        .foregroundStyle(Color.rcmsAccent)
                }
                Image(systemName: "chevron.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.rcmsTextSecondary.opacity(0.5))
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }

    private func preferenceRow<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            rowIcon(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.rcmsTextPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            content()
        }
        .padding(16)
    }

    private func rowIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.rcmsTextPrimary.opacity(0.78))
            .frame(width: 30, height: 30)
    }

    private var divider: some View {
        Divider().padding(.horizontal, 16).opacity(0.5)
    }

    private func toastView(_ payload: SettingsToastPayload) -> some View {
        HStack(spacing: 8) {
            Image(systemName: payload.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(payload.isError ? Color.rcmsDanger : Color.rcmsOnline)
            Text(payload.message)
                .font(.footnote.bold())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }

    private func initialLoadIfNeeded() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        syncProfileDraftsIfNeeded()
        await refreshNotificationAuthorization()
        await viewModel.fetchProfile()
        syncProfileDraftsIfNeeded()
    }

    private func refreshAll() async {
        await refreshNotificationAuthorization()
        await viewModel.fetchProfile()
        syncProfileDraftsIfNeeded()
    }

    private func syncProfileDraftsIfNeeded() {
        guard !isEditingProfile, let user = resolvedUser else { return }
        nicknameDraft = displayName(for: user)
        avatarURLDraft = avatarURL(for: user) ?? ""
    }

    private func startProfileEditing(using user: User) {
        nicknameDraft = displayName(for: user)
        avatarURLDraft = avatarURL(for: user) ?? ""
        selectedAvatarItem = nil
        pendingAvatarImage = nil
        profileErrorMessage = nil
        isEditingProfile = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusNicknameField = true
        }
    }

    private func cancelProfileEditing() {
        syncProfileDraftsIfNeeded()
        selectedAvatarItem = nil
        pendingAvatarImage = nil
        profileErrorMessage = nil
        isEditingProfile = false
    }

    private var profileAvatarSelection: Binding<PhotosPickerItem?> {
        Binding(
            get: { selectedAvatarItem },
            set: { item in
                selectedAvatarItem = item
                guard let item else { return }
                Task { await prepareProfileAvatarCrop(from: item) }
            }
        )
    }

    private func prepareProfileAvatarCrop(from item: PhotosPickerItem) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        profileErrorMessage = nil
        defer {
            isUploadingAvatar = false
            selectedAvatarItem = nil
        }

        do {
            pendingAvatarImage = PendingAvatarImage(image: try await AvatarUploadService.loadImage(from: item))
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    private func uploadProfileAvatarImage(_ image: UIImage) async {
        guard !isUploadingAvatar else { return }
        isUploadingAvatar = true
        profileErrorMessage = nil
        defer {
            isUploadingAvatar = false
        }

        do {
            let prefix = resolvedUser?.username ?? "profile"
            avatarURLDraft = try await AvatarUploadService.uploadAvatarImage(image, fileNamePrefix: prefix)
            presentToast("Avatar uploaded")
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    private func saveProfileChanges(for user: User) async {
        let trimmedNickname = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAvatarURL = avatarURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNickname.isEmpty {
            profileErrorMessage = "Display name cannot be empty"
            return
        }
        do {
            _ = try await viewModel.updateProfile(nickname: trimmedNickname, avatarURL: trimmedAvatarURL)
            withAnimation { isEditingProfile = false }
            presentToast("Profile updated")
        } catch {
            profileErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    private func submitPasswordChange() async {
        passwordErrorMessage = nil
        if newPassword.count < 8 {
            passwordErrorMessage = "New password must be at least 8 characters"
            return
        }
        if newPassword != confirmPassword {
            passwordErrorMessage = "New passwords do not match"
            return
        }
        do {
            try await viewModel.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            resetPasswordForm()
            withAnimation { showPasswordEditor = false }
            presentToast("Password updated")
        } catch {
            passwordErrorMessage = SettingsViewModel.message(from: error)
        }
    }

    private func resetPasswordForm() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordErrorMessage = nil
    }

    private func refreshNotificationAuthorization() async {
        let settings = await notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        if !hasNotificationPermission { botNotificationsEnabled = false }
    }

    private func updateNotifications(enabled: Bool) async {
        if !enabled {
            botNotificationsEnabled = false
            presentToast("Notifications turned off")
            return
        }
        if hasNotificationPermission {
            botNotificationsEnabled = true
            presentToast("Notifications turned on")
            return
        }
        let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotificationAuthorization()
        if granted == true {
            botNotificationsEnabled = true
            presentToast("Notifications turned on")
        } else {
            botNotificationsEnabled = false
            presentToast("Notification permission was not granted", isError: true)
        }
    }

    private func presentToast(_ message: String, isError: Bool = false) {
        let payload = SettingsToastPayload(message: message, isError: isError)
        withAnimation(.spring(response: 0.3)) { toast = payload }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if toast?.id == payload.id { withAnimation { toast = nil } }
        }
    }

    private var normalizedAvatarDraft: String? {
        let trimmed = avatarURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func effectiveDraftName(for user: User) -> String {
        let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.username : trimmed
    }

    private func displayName(for user: User) -> String {
        user.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? user.nickname! : user.username
    }

    private func avatarURL(for user: User) -> String? {
        user.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? user.avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func dateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return Self.dateFormatter.string(from: date)
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private var notificationSubtitle: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional: return botNotificationsEnabled ? "On" : "Allowed"
        case .denied: return "Blocked"
        default: return "Off"
        }
    }

    private var imageUploadQualitySubtitle: String {
        switch imageUploadQuality {
        case "Original":
            return "Original"
        case "Compressed":
            return "Small"
        default:
            return "Balanced"
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (.some(version), .some(build)):
            return "Version \(version) (\(build))"
        case let (.some(version), .none):
            return "Version \(version)"
        case let (.none, .some(build)):
            return "Build \(build)"
        default:
            return "OpenClaw Bot Chat"
        }
    }

    private var realtimeConnectionText: String {
        switch realtimeService.connectionState {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        }
    }

    private var realtimeConnectionIcon: String {
        switch realtimeService.connectionState {
        case .connected:
            return "bolt.horizontal.circle.fill"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "wifi.slash"
        case .idle:
            return "power"
        }
    }

    private static let imageUploadQualityOptions = ["Compressed", "Balanced", "Original"]
    private static let coralDanger = Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()
}


private struct ProfileAvatarView: View {
    let name: String
    let imageURL: String?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 224 / 255, green: 242 / 255, blue: 254 / 255),
                            Color(red: 186 / 255, green: 230 / 255, blue: 253 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url = APIClient.shared.resolvedURL(from: imageURL) {
                RemoteAvatarImage(url: url) {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.rcmsAvatarBorder, lineWidth: 3)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 18, x: 0, y: 10)
    }

    private var initials: some View {
        Text(initialsText)
            .font(.system(size: diameter * 0.28, weight: .bold, design: .rounded))
            .foregroundStyle(Color.rcmsAccent)
    }

    private var initialsText: String {
        let pieces = name
            .split(whereSeparator: \.isWhitespace)
            .map { String($0.prefix(1)).uppercased() }

        return String(pieces.joined().prefix(2))
    }
}

private struct SettingsToastPayload: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

#Preview("Settings") {
    SettingsView(previewUser: User(
        id: UUID(),
        username: "alex",
        email: "alex@openclaw.dev-lcoalsdfsdfsd",
        nickname: "Alex Chen -msdfsdfsdf",
        avatar: nil,
        avatarUrl: nil,
        createdAt: Date(timeIntervalSince1970: 1_764_028_800),
        updatedAt: nil
    ))
    .preferredColorScheme(.light)
}
