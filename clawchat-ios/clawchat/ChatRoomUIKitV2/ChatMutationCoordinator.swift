import Foundation
import UIKit

@MainActor
final class ChatMutationCoordinator {
    private var isApplyingTableMutation = false
    private var pendingKeyboardInset: CGFloat?

    func beginTableMutation() {
        isApplyingTableMutation = true
    }

    func finishTableMutation() {
        isApplyingTableMutation = false
    }

    func applyKeyboardInset(_ inset: CGFloat, to tableView: UITableView) {
        guard !isApplyingTableMutation else {
            pendingKeyboardInset = inset
            return
        }
        setKeyboardInset(inset, on: tableView)
    }

    func flushPendingKeyboardInset(to tableView: UITableView) {
        guard let inset = pendingKeyboardInset else { return }
        pendingKeyboardInset = nil
        setKeyboardInset(inset, on: tableView)
    }

    private func setKeyboardInset(_ inset: CGFloat, on tableView: UITableView) {
        var contentInset = tableView.contentInset
        var scrollIndicatorInsets = tableView.verticalScrollIndicatorInsets
        contentInset.bottom = inset
        scrollIndicatorInsets.bottom = inset
        tableView.contentInset = contentInset
        tableView.verticalScrollIndicatorInsets = scrollIndicatorInsets
        ChatDiagnostics.logMutation(.keyboardInset(inset))
    }
}
