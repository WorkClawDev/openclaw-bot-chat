import SwiftUI
import UIKit

extension Color {
    fileprivate static func rcmsDynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let rcmsSurface = rcmsDynamic(light: .white, dark: UIColor(white: 0.11, alpha: 1))
    static let rcmsSurfaceSolid = rcmsSurface
    static let rcmsSurfaceElevated = rcmsDynamic(light: .white, dark: UIColor(white: 0.15, alpha: 1))
    static let rcmsSurfaceMuted = rcmsDynamic(light: UIColor(white: 0.95, alpha: 1), dark: UIColor(white: 0.16, alpha: 1))
    static let rcmsControlSurface = rcmsSurfaceMuted
    static let rcmsFieldSurface = rcmsSurfaceMuted
    static let rcmsSubtleFill = rcmsDynamic(light: UIColor(white: 0, alpha: 0.025), dark: UIColor(white: 1, alpha: 0.06))
    static let rcmsAccentSoft = rcmsSurfaceMuted
    static let rcmsAccentSofter = rcmsDynamic(light: UIColor(white: 0.9, alpha: 1), dark: UIColor(white: 0.22, alpha: 1))
    static let rcmsWarning = Color.orange
    static let rcmsAccent = Color(UIColor.chatOutgoing)
    static let rcmsOnline = Color(red: 0.19, green: 0.63, blue: 0.42)
    static let rcmsOffline = Color.secondary
    static let rcmsDanger = Color.red
    static let rcmsBackground = rcmsDynamic(light: .white, dark: UIColor(white: 0.07, alpha: 1))
    static let rcmsTextPrimary = Color.primary
    static let rcmsTextStrong = Color.primary
    static let rcmsTextSecondary = Color.secondary
    static let rcmsDivider = rcmsDynamic(light: UIColor(white: 0, alpha: 0.06), dark: UIColor(white: 1, alpha: 0.1))
    static let rcmsToolbarSurface = rcmsBackground

    static let rcmsHairline = rcmsDynamic(
        light: UIColor(white: 0, alpha: 0.06),
        dark: UIColor(white: 1, alpha: 0.12)
    )
    static let rcmsAvatarBorder = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.95),
        dark: UIColor(red: 51/255, green: 65/255, blue: 85/255, alpha: 1)
    )
    static let rcmsImageBorder = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.72),
        dark: UIColor(red: 71/255, green: 85/255, blue: 105/255, alpha: 0.92)
    )
    static let rcmsIncomingBubble = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.95),
        dark: UIColor(red: 30/255, green: 41/255, blue: 59/255, alpha: 0.95)
    )
    static let rcmsCodeBlockBackground = rcmsDynamic(
        light: UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1),
        dark: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
    )
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.t("系统", "System")
        case .light:
            return L10n.t("浅色", "Light")
        case .dark:
            return L10n.t("深色", "Dark")
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            return L10n.t("跟随系统外观", "Uses iOS appearance")
        case .light:
            return L10n.t("明亮的日间配色", "Bright daytime palette")
        case .dark:
            return L10n.t("深夜配色", "Deep night palette")
        }
    }

    var systemImage: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum UITheme {
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let tight: CGFloat = 6
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
    }

    enum Shadow {
        static let cardColor = Color.rcmsDynamic(
            light: UIColor(white: 0, alpha: 0.08),
            dark: UIColor(white: 0, alpha: 0.35)
        )
        static let cardRadius: CGFloat = 16
        static let cardYOffset: CGFloat = 8
        static let accentColor = Color.rcmsAccent.opacity(0.3)
    }

    static let cardStroke = Color.rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.9),
        dark: UIColor(white: 1, alpha: 0.12)
    )
    static let subtleStroke = Color.rcmsDynamic(
        light: UIColor(white: 0, alpha: 0.05),
        dark: UIColor(white: 1, alpha: 0.12)
    )

    static var avatarGradient: LinearGradient {
        LinearGradient(
            colors: [Color.rcmsAccentSoft, Color.rcmsAccentSofter],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var neutralAvatarGradient: LinearGradient {
        LinearGradient(
            colors: [Color.rcmsSurfaceSolid, Color.rcmsSurfaceMuted],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct FrostedBackground: View {
    var body: some View {
        Color.rcmsBackground
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.rcmsSurface)
            .clipShape(RoundedRectangle(cornerRadius: UITheme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UITheme.Radius.large, style: .continuous)
                    .stroke(UITheme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func glassCardStyle() -> some View {
        modifier(GlassCard())
    }
}

// Shared by SwiftUI chrome and UIKit cells so appearance changes do not alter geometry.
extension UIColor {
    static let chatOutgoing = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.23 : 0.16, alpha: 1)
    }
    static let chatIncoming = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 0.14 : 0.95, alpha: 1)
    }
}

enum ChatLayoutMetrics {
    static let horizontalInset: CGFloat = 16
    static let verticalInset: CGFloat = 5
    static let blockSpacing: CGFloat = 8
    static func bubbleWidth(in width: CGFloat) -> CGFloat {
        min(520, floor((width - horizontalInset * 2) * 0.86))
    }
}
