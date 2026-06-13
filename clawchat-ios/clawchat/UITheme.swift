import SwiftUI
import UIKit

extension Color {
    fileprivate static func rcmsDynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let rcmsSurface = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.78),
        dark: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 0.84)
    )
    static let rcmsSurfaceSolid = rcmsDynamic(
        light: UIColor.white,
        dark: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1)
    )
    static let rcmsSurfaceElevated = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.95),
        dark: UIColor(red: 30/255, green: 41/255, blue: 59/255, alpha: 0.96)
    )
    static let rcmsSurfaceMuted = rcmsDynamic(
        light: UIColor(red: 241/255, green: 245/255, blue: 249/255, alpha: 1),
        dark: UIColor(red: 30/255, green: 41/255, blue: 59/255, alpha: 1)
    )
    static let rcmsControlSurface = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.72),
        dark: UIColor(red: 30/255, green: 41/255, blue: 59/255, alpha: 0.82)
    )
    static let rcmsFieldSurface = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.86),
        dark: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 0.9)
    )
    static let rcmsSubtleFill = rcmsDynamic(
        light: UIColor(white: 0, alpha: 0.02),
        dark: UIColor(white: 1, alpha: 0.08)
    )
    static let rcmsAccentSoft = rcmsDynamic(
        light: UIColor(red: 224/255, green: 242/255, blue: 254/255, alpha: 1),
        dark: UIColor(red: 8/255, green: 47/255, blue: 73/255, alpha: 1)
    )
    static let rcmsAccentSofter = rcmsDynamic(
        light: UIColor(red: 186/255, green: 230/255, blue: 253/255, alpha: 1),
        dark: UIColor(red: 12/255, green: 74/255, blue: 110/255, alpha: 1)
    )
    static let rcmsWarning = Color(red: 245/255, green: 158/255, blue: 11/255)

    static let rcmsAccent = Color(red: 14/255, green: 165/255, blue: 233/255)
    static let rcmsOnline = Color(red: 16/255, green: 185/255, blue: 129/255)
    static let rcmsOffline = Color(red: 148/255, green: 163/255, blue: 184/255)
    static let rcmsDanger = Color(red: 239/255, green: 68/255, blue: 68/255)

    static let rcmsBackground = rcmsDynamic(
        light: UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1),
        dark: UIColor(red: 2/255, green: 6/255, blue: 23/255, alpha: 1)
    )
    static let rcmsTextPrimary = rcmsDynamic(
        light: UIColor(red: 30/255, green: 41/255, blue: 59/255, alpha: 1),
        dark: UIColor(red: 226/255, green: 232/255, blue: 240/255, alpha: 1)
    )
    static let rcmsTextStrong = rcmsDynamic(
        light: UIColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1),
        dark: UIColor(red: 248/255, green: 250/255, blue: 252/255, alpha: 1)
    )
    static let rcmsTextSecondary = rcmsDynamic(
        light: UIColor(red: 100/255, green: 116/255, blue: 139/255, alpha: 1),
        dark: UIColor(red: 203/255, green: 213/255, blue: 225/255, alpha: 1)
    )
    static let rcmsDivider = rcmsDynamic(
        light: UIColor(white: 0, alpha: 0.05),
        dark: UIColor(white: 1, alpha: 0.12)
    )
    static let rcmsToolbarSurface = rcmsDynamic(
        light: UIColor(white: 1, alpha: 0.82),
        dark: UIColor(red: 2/255, green: 6/255, blue: 23/255, alpha: 0.86)
    )
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
        LinearGradient(
            colors: [Color.rcmsBackground, Color.rcmsSurfaceMuted],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.rcmsSurface)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: UITheme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UITheme.Radius.large, style: .continuous)
                    .stroke(UITheme.cardStroke, lineWidth: 1)
            )
            .shadow(color: UITheme.Shadow.cardColor, radius: UITheme.Shadow.cardRadius, x: 0, y: UITheme.Shadow.cardYOffset)
    }
}

extension View {
    func glassCardStyle() -> some View {
        modifier(GlassCard())
    }
}
