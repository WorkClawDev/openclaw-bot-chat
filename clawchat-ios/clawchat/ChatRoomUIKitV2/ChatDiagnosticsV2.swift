import Foundation
import UIKit

@MainActor
final class ChatDiagnosticsV2 {
    private(set) var initialReloadCount = 0
    private(set) var unexpectedReloadDataCount = 0
    private(set) var prependCount = 0
    private(set) var appendCount = 0
    private(set) var updateCount = 0
    private(set) var restoreCount = 0
    private(set) var maxAnchorDrift: CGFloat = 0
    private(set) var keyboardInsetDuringPrependCount = 0
    private(set) var keyboardRestoreCount = 0

    func recordInitialReload() {
        initialReloadCount += 1
    }

    func recordUnexpectedReloadData() {
        unexpectedReloadDataCount += 1
    }

    func recordPrepend() {
        prependCount += 1
    }

    func recordAppend() {
        appendCount += 1
    }

    func recordUpdate() {
        updateCount += 1
    }

    func recordRestore() {
        restoreCount += 1
    }

    func recordAnchorDrift(_ drift: CGFloat) {
        maxAnchorDrift = max(maxAnchorDrift, abs(drift))
    }

    func recordKeyboardInsetDuringPrepend() {
        keyboardInsetDuringPrependCount += 1
    }

    func recordKeyboardRestore() {
        keyboardRestoreCount += 1
    }

    func summary(messageCount: Int) -> String {
        "messages=\(messageCount); prepends=\(prependCount); appends=\(appendCount); updates=\(updateCount); restores=\(restoreCount); reloads=\(unexpectedReloadDataCount); drift=\(String(format: "%.2f", maxAnchorDrift)); keyboardOverlap=\(keyboardInsetDuringPrependCount); keyboardRestores=\(keyboardRestoreCount)"
    }
}
