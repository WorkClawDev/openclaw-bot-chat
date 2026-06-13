import SwiftUI
import PhotosUI
import UIKit

extension SettingsView {
    var loadingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.rcmsAccent)
            Text(L10n.t("正在加载个人资料", "Loading your profile"))
                .font(.subheadline)
                .foregroundStyle(Color.rcmsTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    func compactSettingsContent(user: User) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsHeader

            profileHeader(user: user)

            sectionHeader(title: L10n.t("账号", "Account"))
            accountCard(user: user)

            sectionHeader(title: L10n.t("外观", "Appearance"))
            appearanceCard

            sectionHeader(title: L10n.t("语言", "Language"))
            languageCard

            sectionHeader(title: L10n.t("消息", "Messaging"))
            messagingCard

            sectionHeader(title: L10n.t("系统", "System"))
            systemCard

            sectionHeader(title: L10n.t("关于", "About"))
            aboutCard

            logoutButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    func wideSettingsContent(user: User) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("设置", "Settings"))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text(L10n.t("个人资料、消息偏好和连接状态", "Profile, messaging preferences, and broker state"))
                        .font(.subheadline)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }

                Spacer()

                IpadSettingsStatusPill(text: realtimeConnectionText, systemImage: realtimeConnectionIcon, tint: realtimeStatusTint)
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    profileHeader(user: user)
                    accountCard(user: user)
                    logoutButton
                }
                .frame(maxWidth: 460, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 18) {
                    appearanceCard
                    languageCard
                    messagingCard
                    wideSystemOverview
                    aboutCard
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 36)
        .frame(maxWidth: 980, alignment: .topLeading)
    }

    func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.rcmsTextSecondary)
            .padding(.leading, 4)
            .padding(.bottom, -8)
    }

    var settingsHeader: some View {
        Text(L10n.t("设置", "Settings"))
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .foregroundStyle(Color.rcmsTextStrong)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    func profileHeader(user: User) -> some View {
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
                    Text(isEditingProfile ? L10n.t("取消", "Cancel") : L10n.t("编辑", "Edit"))
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
                .buttonStyle(.plain)
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
                            Text(L10n.t("头像", "Profile photo"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.rcmsTextPrimary)
                            Text(isUploadingAvatar ? L10n.t("上传中", "Uploading") : L10n.t("上传前可拖动和缩放", "Drag and zoom before uploading"))
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
                        .accessibilityLabel(L10n.t("选择头像", "Choose avatar"))
                    }
                    .padding(12)
                    .background(Color.rcmsSubtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    editField(title: L10n.t("显示名称", "Display name"), placeholder: L10n.t("添加显示名称", "Add a display name"), text: $nicknameDraft)
                        .focused($focusNicknameField)
                    
                    editField(title: L10n.t("头像链接", "Avatar URL"), placeholder: L10n.t("图片链接", "HTTPS image link"), text: $avatarURLDraft)

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
                            Text(L10n.t("保存资料", "Save profile"))
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.rcmsAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .buttonStyle(.plain)
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

    func editField(title: String, placeholder: String, text: Binding<String>) -> some View {
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

    func accountCard(user: User) -> some View {
        VStack(spacing: 0) {
            actionRow(title: L10n.t("个人资料", "Profile"), subtitle: "", value: "", icon: "person") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    startProfileEditing(using: user)
                }
            }
            divider
            actionRow(title: L10n.t("密码", "Password"), subtitle: "", value: "", icon: "lock") {
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

            actionRow(title: L10n.t("设备", "Devices"), subtitle: "", value: "", icon: "iphone") {
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

    var passwordEditor: some View {
        VStack(spacing: 12) {
            SecureField(L10n.t("当前密码", "Current password"), text: $currentPassword)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            SecureField(L10n.t("新密码（至少 8 个字符）", "New password (at least 8 characters)"), text: $newPassword)
                .padding(12)
                .background(Color.rcmsFieldSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
            SecureField(L10n.t("确认新密码", "Confirm new password"), text: $confirmPassword)
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
                    Text(L10n.t("更新密码", "Update password")).bold()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.rcmsAccent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .buttonStyle(.plain)
            .disabled(viewModel.isChangingPassword)
        }
        .padding(12)
        .background(Color.rcmsSubtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: AppPlatform.deviceSymbolName)
                    .font(.title3)
                    .foregroundStyle(Color.rcmsAccent)
                
                VStack(alignment: .leading) {
                    Text(AppPlatform.deviceDisplayName)
                        .font(.subheadline.bold())
                    Text(AppPlatform.operatingSystemDescription)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                }
                Spacer()
                Text(L10n.t("在线", "Online")).font(.caption.bold()).foregroundStyle(Color.rcmsOnline)
            }
        }
        .padding(12)
        .background(Color.rcmsSubtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                rowIcon(appearanceMode.systemImage)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("外观模式", "Appearance mode"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.rcmsTextPrimary)
                    Text(appearanceMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Picker(L10n.t("外观", "Appearance"), selection: $appearanceModeRawValue) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .id("appearance-\(languageModeRawValue)")
            .pickerStyle(.segmented)
        }
        .padding(16)
        .glassCardStyle()
    }

    var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                rowIcon("globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("界面语言", "App language"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.rcmsTextPrimary)
                    Text(languageMode.subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.rcmsTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Picker(L10n.t("语言", "Language"), selection: $languageModeRawValue) {
                ForEach(AppLanguageMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .id("language-\(languageModeRawValue)")
            .pickerStyle(.segmented)
        }
        .padding(16)
        .glassCardStyle()
    }

    var messagingCard: some View {
        VStack(spacing: 0) {
            preferenceRow(title: L10n.t("机器人通知", "Bot notifications"), subtitle: notificationSubtitle, icon: "bell.badge") {
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
            preferenceRow(title: L10n.t("紧凑消息模式", "Compact message mode"), subtitle: compactMessageMode ? L10n.t("紧凑", "Compact") : L10n.t("舒适", "Comfort"), icon: "text.alignleft") {
                Toggle("", isOn: $compactMessageMode)
                    .labelsHidden()
                    .tint(Color.rcmsAccent)
            }
            divider
            preferenceRow(title: L10n.t("图片上传质量", "Image upload quality"), subtitle: imageUploadQualitySubtitle, icon: "photo.on.rectangle") {
                Picker(L10n.t("图片上传质量", "Image upload quality"), selection: $imageUploadQuality) {
                    ForEach(Self.imageUploadQualityOptions, id: \.self) { quality in
                        Text(Self.localizedImageUploadQuality(quality)).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.rcmsAccent)
            }
        }
        .glassCardStyle()
    }

    var systemCard: some View {
        VStack(spacing: 0) {
            infoRow(title: L10n.t("实时连接", "Realtime connection"), value: realtimeConnectionText, icon: realtimeConnectionIcon)
            divider
            infoRow(title: L10n.t("接口地址", "API endpoint"), value: APIClient.shared.baseURL.absoluteString, icon: "network", isMonospaced: true, copyString: APIClient.shared.baseURL.absoluteString)
        }
        .glassCardStyle()
    }

    var wideSystemOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("系统", "System"))
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)

            HStack(spacing: 12) {
                IpadSettingsInfoTile(title: L10n.t("实时", "Realtime"), value: realtimeConnectionText, systemImage: realtimeConnectionIcon, tint: realtimeStatusTint)
                IpadSettingsInfoTile(title: L10n.t("设备", "Device"), value: AppPlatform.deviceDisplayName, systemImage: AppPlatform.deviceSymbolName, tint: Color.rcmsAccent)
            }

            infoRow(title: L10n.t("接口地址", "API endpoint"), value: APIClient.shared.baseURL.absoluteString, icon: "network", isMonospaced: true, copyString: APIClient.shared.baseURL.absoluteString)
                .background(Color.rcmsSubtleFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .glassCardStyle()
    }

    var aboutCard: some View {
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

    var logoutButton: some View {
        Button {
            authManager.logout()
        } label: {
            HStack {
                Text(L10n.t("退出登录", "Log out"))
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
        .buttonStyle(.plain)
    }

    func infoRow(title: String, value: String, icon: String, isMonospaced: Bool = false, copyString: String? = nil) -> some View {
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
                        presentToast(L10n.t("已复制到剪贴板", "Copied to clipboard"))
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(Color.rcmsAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }

    func actionRow(title: String, subtitle: String, value: String, icon: String, action: @escaping () -> Void) -> some View {
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

    func preferenceRow<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
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

    func rowIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.rcmsTextPrimary.opacity(0.78))
            .frame(width: 30, height: 30)
    }

    var divider: some View {
        Divider().padding(.horizontal, 16).opacity(0.5)
    }

    var realtimeStatusTint: Color {
        switch realtimeService.connectionState {
        case .connected:
            return Color.rcmsOnline
        case .connecting:
            return Color.rcmsWarning
        case .idle, .disconnected:
            return Color.rcmsOffline
        }
    }

    func toastView(_ payload: SettingsToastPayload) -> some View {
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
}

private struct IpadSettingsStatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct IpadSettingsInfoTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.rcmsTextStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.rcmsTextSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(14)
        .background(Color.rcmsSubtleFill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
