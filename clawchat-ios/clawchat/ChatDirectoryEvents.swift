import Foundation

extension Notification.Name {
    /// Posted only after the server acknowledges a bot/group mutation.
    static let chatDirectoryDidChange = Notification.Name("ChatDirectoryDidChange")
}
