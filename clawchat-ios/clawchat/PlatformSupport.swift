import Foundation
import SwiftUI
import UIKit

enum AppPlatform {
    static var usesDesktopPresentation: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        UIDevice.current.userInterfaceIdiom == .pad
#endif
    }

    static var isMacCatalyst: Bool {
#if targetEnvironment(macCatalyst)
        true
#else
        false
#endif
    }

    static var deviceSymbolName: String {
        if isMacCatalyst {
            return "desktopcomputer"
        }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    static var deviceDisplayName: String {
        if isMacCatalyst {
            let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            return hostName.isEmpty ? "Mac" : hostName
        }
        return UIDevice.current.name
    }

    static var operatingSystemDescription: String {
        if isMacCatalyst {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) · Current Mac"
        }
        return "iOS \(UIDevice.current.systemVersion) · Current device"
    }
}
