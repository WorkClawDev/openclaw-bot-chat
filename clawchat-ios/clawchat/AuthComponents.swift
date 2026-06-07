import SwiftUI

func authBrandHeader(title: String, subtitle: String, logoSize: CGFloat) -> some View {
    VStack(spacing: 18) {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: logoSize, height: logoSize)
            .clipShape(RoundedRectangle(cornerRadius: logoSize > 80 ? 26 : 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 14, y: 8)
            .padding(.top, 28)

        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.rcmsTextStrong)

            Text(subtitle)
                .font(.body)
                .foregroundStyle(Color.rcmsTextSecondary)
                .multilineTextAlignment(.center)
        }
    }
}

func capabilityCard(_ rows: [(String, String)]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            CapabilityRow(icon: row.0, text: row.1)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(Color.rcmsControlSurface)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.rcmsHairline, lineWidth: 1)
    )
}

var divider: some View {
    Rectangle()
        .fill(Color.rcmsDivider)
        .frame(height: 1)
        .padding(.horizontal, 20)
}

struct AuthTextInput: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(error == nil ? Color.rcmsAccent : Color.rcmsDanger)
                    .frame(width: 22)

                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.rcmsTextPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.rcmsFieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(error == nil ? Color.rcmsHairline : Color.rcmsDanger.opacity(0.55), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.rcmsDanger)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct AuthSecureInput: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(error == nil ? Color.rcmsAccent : Color.rcmsDanger)
                    .frame(width: 22)

                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.rcmsTextPrimary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color.rcmsFieldSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(error == nil ? Color.rcmsHairline : Color.rcmsDanger.opacity(0.55), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.rcmsDanger)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct AuthPrimaryButtonLabel: View {
    let title: String
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(.white)
            } else {
                Text(title)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(Color.rcmsAccent)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.rcmsAccent.opacity(0.26), radius: 10, y: 5)
    }
}

struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .padding(.top, 1)
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(Color.rcmsDanger)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.rcmsDanger.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PasswordRequirementRow: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isMet ? Color.rcmsOnline : Color.rcmsTextSecondary.opacity(0.55))
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.rcmsTextSecondary)
        }
    }
}

struct CapabilityRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.rcmsOnline)

            Image(systemName: icon)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.rcmsTextSecondary)
                .frame(width: 28)

            Text(text)
                .font(.body)
                .foregroundStyle(Color.rcmsTextPrimary)
        }
    }
}

struct AuthView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LoginView()
                .previewDisplayName("Login")
            RegisterView()
                .previewDisplayName("Register")
        }
        .preferredColorScheme(.light)
    }
}
