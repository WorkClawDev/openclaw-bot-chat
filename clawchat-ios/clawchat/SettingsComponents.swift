import SwiftUI

struct ProfileAvatarView: View {
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

struct SettingsToastPayload: Identifiable, Equatable {
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
