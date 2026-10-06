import SwiftUI

// Present above the active sheet as well as ordinary navigation. A notification
// must not discard the user's settings form, attachment draft or previous chat.
struct ChatPushPresentationHost: UIViewControllerRepresentable {
    @ObservedObject var notifications: ChatPushNotifications

    func makeCoordinator() -> Coordinator { Coordinator(notifications) }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.becameVisible = { [weak coordinator = context.coordinator, weak anchor] in
            guard let anchor else { return }
            coordinator?.reconcile(from: anchor)
        }
        return anchor
    }

    func updateUIViewController(_ anchor: Anchor, context: Context) {
        context.coordinator.reconcile(from: anchor)
    }

    final class Anchor: UIViewController {
        var becameVisible: (() -> Void)?
        override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becameVisible?() }
    }

    final class Coordinator {
        private let notifications: ChatPushNotifications
        private var presented: UIViewController?
        private var presentedError: UIAlertController?
        private var transitioning = false
        init(_ notifications: ChatPushNotifications) { self.notifications = notifications }

        func reconcile(from anchor: UIViewController) {
            guard !transitioning else { return }
            // A root SwiftUI alert dismisses the active sheet. Present errors
            // from the current top controller instead, preserving the user's
            // settings editor, chat or attachment draft underneath it.
            if let alert = presentedError {
                if let message = notifications.navigationError {
                    alert.message = message
                } else if alert.presentingViewController == nil {
                    presentedError = nil
                    reconcile(from: anchor)
                } else {
                    transitioning = true
                    alert.dismiss(animated: true) { [weak self, weak anchor] in
                        self?.presentedError = nil
                        self?.transitioning = false
                        if let anchor { self?.reconcile(from: anchor) }
                    }
                }
                return
            }
            if let message = notifications.navigationError {
                guard let top = presenter(from: anchor) else { return }
                let alert = UIAlertController(title: L10n.t("无法打开聊天", "Could not open chat"), message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.t("确定", "OK"), style: .default) { [weak self] _ in
                    self?.notifications.navigationError = nil
                })
                presentedError = alert
                transitioning = true
                top.present(alert, animated: true) { [weak self, weak anchor] in
                    self?.transitioning = false
                    if let anchor { self?.reconcile(from: anchor) }
                }
                return
            }
            if notifications.destination == nil {
                guard let presented else { return }
                transitioning = true
                presented.dismiss(animated: true) { [weak self, weak anchor] in
                    self?.presented = nil
                    self?.transitioning = false
                    if let anchor { self?.reconcile(from: anchor) }
                }
                return
            }
            guard presented == nil, let top = presenter(from: anchor) else { return }
            let host = UIHostingController(rootView: NotificationChat(notifications: notifications))
            host.modalPresentationStyle = .fullScreen
            presented = host
            transitioning = true
            top.present(host, animated: true) { [weak self, weak anchor] in
                self?.transitioning = false
                if let anchor { self?.reconcile(from: anchor) }
            }
        }

        private func presenter(from anchor: UIViewController) -> UIViewController? {
            guard var top = anchor.viewIfLoaded?.window?.rootViewController else { return nil }
            while let next = top.presentedViewController { top = next }
            if let transition = top.transitionCoordinator {
                transitioning = true
                transition.animate(alongsideTransition: nil) { [weak self, weak anchor] _ in
                    self?.transitioning = false
                    if let anchor { self?.reconcile(from: anchor) }
                }
                return nil
            }
            return top
        }
    }
}

private struct NotificationChat: View {
    @ObservedObject var notifications: ChatPushNotifications
    var body: some View {
        if let destination = notifications.destination {
            NavigationStack {
                ChatRoomView(context: destination.context)
                    .environment(\.closeNotificationChat, { notifications.destination = nil })
            }.id(destination.id)
        }
    }
}
