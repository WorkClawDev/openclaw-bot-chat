import SwiftUI
import PhotosUI
import UIKit

extension SettingsView {
    var loadingIndicator: some View {
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

    func compactSettingsContent(user: User) -> some View {
        VStack(alignment: .leading, spacing: 20) {
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    func wideSettingsContent(user: User) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rcmsTextStrong)
                    Text("Profile, messaging preferences, and broker state")
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
        Text("Settings")
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

    var passwordEditor: some View {
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
                Text("Online").font(.caption.bold()).foregroundStyle(Color.rcmsOnline)
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

    var messagingCard: some View {
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

    var systemCard: some View {
        VStack(spacing: 0) {
            infoRow(title: "Realtime connection", value: realtimeConnectionText, icon: realtimeConnectionIcon)
            divider
            infoRow(title: "API endpoint", value: APIClient.shared.baseURL.absoluteString, icon: "network", isMonospaced: true, copyString: APIClient.shared.baseURL.absoluteString)
        }
        .glassCardStyle()
    }

    var wideSystemOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("System")
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.rcmsTextStrong)

            HStack(spacing: 12) {
                IpadSettingsInfoTile(title: "Realtime", value: realtimeConnectionText, systemImage: realtimeConnectionIcon, tint: realtimeStatusTint)
                IpadSettingsInfoTile(title: "Device", value: AppPlatform.deviceDisplayName, systemImage: AppPlatform.deviceSymbolName, tint: Color.rcmsAccent)
            }

            infoRow(title: "API endpoint", value: APIClient.shared.baseURL.absoluteString, icon: "network", isMonospaced: true, copyString: APIClient.shared.baseURL.absoluteString)
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
                        presentToast("Copied to clipboard")
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
