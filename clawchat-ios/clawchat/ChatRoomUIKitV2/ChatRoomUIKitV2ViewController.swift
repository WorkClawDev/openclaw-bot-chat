import Foundation
import SwiftUI
import UIKit

enum ChatRoomImplementation {
    case legacy
    case uikitV2
}

final class ChatRoomV2TableView: UITableView {
    var permitsInitialReloadData = true

    override func reloadData() {
        if !permitsInitialReloadData {
            ChatDiagnostics.logUnexpectedReloadData()
        }
        super.reloadData()
    }
}

@MainActor
final class ChatRoomUIKitV2ViewController: UIViewController {
    private let tableView = ChatRoomV2TableView(frame: .zero, style: .plain)
    private let store = ChatMessageStore()
    private let mutationCoordinator = ChatMutationCoordinator()
    private let renderCoordinator: MessageRenderCoordinator
    private lazy var paginationController = ChatPaginationController(pageSize: Self.historyPageSize) { pageIndex, pageSize in
        ChatRoomV2MockMessageFactory.historyPage(pageIndex: pageIndex, pageSize: pageSize)
    }

    private var didLoadInitialMessages = false
    private var isHistoryLoadScheduled = false
    private var renderWidth: CGFloat {
        max(1, tableView.bounds.width)
    }

    init(currentUserID: String = ChatRoomV2MockMessageFactory.currentUserID) {
        self.renderCoordinator = MessageRenderCoordinator(currentUserID: currentUserID)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.renderCoordinator = MessageRenderCoordinator(currentUserID: ChatRoomV2MockMessageFactory.currentUserID)
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupTableView()
        observeKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        loadInitialMessagesIfNeeded()
    }

    func runPrependStressTest(iterations: Int = 20) {
        Task { @MainActor in
            for _ in 0..<iterations {
                await loadPreviousPageIfNeeded(force: true)
            }
        }
    }

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.dataSource = self
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: ChatMessageCell.reuseIdentifier)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    private func loadInitialMessagesIfNeeded() {
        guard !didLoadInitialMessages else { return }
        didLoadInitialMessages = true

        Task { @MainActor in
            let rawMessages = ChatRoomV2MockMessageFactory.initialMessages(count: Self.initialMessageCount)
            let renderedMessages = await renderCoordinator.renderPage(rawMessages, width: renderWidth)
            ChatDiagnostics.assertRenderedPageIsLaidOut(renderedMessages)
            store.initialLoad(renderedMessages)
            ChatDiagnostics.logMutation(.initialLoad(count: renderedMessages.count))
            tableView.permitsInitialReloadData = true
            tableView.reloadData()
            tableView.permitsInitialReloadData = false
            scrollToBottom(animated: false)
        }
    }

    private func loadPreviousPageIfNeeded(force: Bool = false) async {
        if !force {
            guard !isHistoryLoadScheduled else { return }
            isHistoryLoadScheduled = true
        }
        defer {
            if !force {
                isHistoryLoadScheduled = false
            }
        }

        let rawPage: [RawMessage]
        if force {
            rawPage = await paginationController.loadPreviousPageIfNeeded(
                contentOffsetY: 0,
                viewportHeight: max(1, tableView.bounds.height)
            )
        } else {
            rawPage = await paginationController.loadPreviousPageIfNeeded(
                contentOffsetY: tableView.contentOffset.y,
                viewportHeight: tableView.bounds.height
            )
        }

        guard !rawPage.isEmpty else { return }
        let renderedPage = await renderCoordinator.renderPage(rawPage, width: renderWidth)
        prependRenderedHistory(renderedPage)
    }

    @MainActor
    private func prependRenderedHistory(_ page: [RenderedMessage]) {
        guard !page.isEmpty else { return }
        ChatDiagnostics.assertRenderedPageIsLaidOut(page)

        let anchor = captureVisibleAnchor()

        store.prependHistory(page)
        ChatDiagnostics.logMutation(.prepend(count: page.count))

        let paths = page.indices.map { IndexPath(row: $0, section: 0) }
        UIView.performWithoutAnimation {
            mutationCoordinator.beginTableMutation()
            tableView.performBatchUpdates {
                tableView.insertRows(at: paths, with: .none)
            } completion: { [weak self] _ in
                guard let self else { return }
                self.restoreVisibleAnchor(anchor)
                if let anchor, let after = self.currentViewportOffset(for: anchor.messageID) {
                    ChatDiagnostics.logAnchorDrift(before: anchor.offsetFromViewportTop, after: after)
                }
                self.mutationCoordinator.finishTableMutation()
                self.mutationCoordinator.flushPendingKeyboardInset(to: self.tableView)
            }
        }
    }

    private func captureVisibleAnchor() -> VisibleMessageAnchor? {
        guard
            let indexPath = tableView.indexPathsForVisibleRows?.min(),
            store.messages.indices.contains(indexPath.row)
        else {
            return nil
        }

        let message = store.messages[indexPath.row]
        let rowRect = tableView.rectForRow(at: indexPath)

        return VisibleMessageAnchor(
            messageID: message.id,
            offsetFromViewportTop: rowRect.minY - tableView.contentOffset.y
        )
    }

    private func restoreVisibleAnchor(_ anchor: VisibleMessageAnchor?) {
        guard
            let anchor,
            let row = store.messages.firstIndex(where: { $0.id == anchor.messageID })
        else {
            return
        }

        tableView.layoutIfNeeded()
        let path = IndexPath(row: row, section: 0)
        let rect = tableView.rectForRow(at: path)
        tableView.setContentOffset(
            CGPoint(x: 0, y: rect.minY - anchor.offsetFromViewportTop),
            animated: false
        )
    }

    private func currentViewportOffset(for messageID: String) -> CGFloat? {
        guard let row = store.messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }
        let path = IndexPath(row: row, section: 0)
        let rect = tableView.rectForRow(at: path)
        return rect.minY - tableView.contentOffset.y
    }

    private func scrollToBottom(animated: Bool) {
        guard !store.messages.isEmpty else { return }
        let lastPath = IndexPath(row: store.messages.count - 1, section: 0)
        tableView.scrollToRow(at: lastPath, at: .bottom, animated: animated)
    }

    @objc
    private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else {
            return
        }

        let keyboardFrameInView = view.convert(frameValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.maxY - keyboardFrameInView.minY)
        mutationCoordinator.applyKeyboardInset(overlap, to: tableView)
    }

    private static let initialMessageCount = 60
    private static let historyPageSize = 30
}

extension ChatRoomUIKitV2ViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ChatMessageCell.reuseIdentifier,
                for: indexPath
            ) as? ChatMessageCell
        else {
            return UITableViewCell(style: .default, reuseIdentifier: nil)
        }

        cell.configure(with: store.messages[indexPath.row])
        return cell
    }
}

extension ChatRoomUIKitV2ViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        store.messages[indexPath.row].layout.rowHeight
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard didLoadInitialMessages else { return }
        guard !isHistoryLoadScheduled else { return }
        guard paginationController.shouldPreload(
            contentOffsetY: scrollView.contentOffset.y,
            viewportHeight: scrollView.bounds.height
        ) else {
            return
        }

        isHistoryLoadScheduled = true
        Task { @MainActor in
            defer {
                isHistoryLoadScheduled = false
            }
            let rawPage = await paginationController.loadPreviousPageIfNeeded(
                contentOffsetY: scrollView.contentOffset.y,
                viewportHeight: scrollView.bounds.height
            )
            guard !rawPage.isEmpty else { return }
            let renderedPage = await renderCoordinator.renderPage(rawPage, width: renderWidth)
            prependRenderedHistory(renderedPage)
        }
    }
}

extension ChatRoomUIKitV2ViewController: UITableViewDataSourcePrefetching {
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // Text-only baseline has no media work to prefetch.
    }
}

struct ChatRoomUIKitV2BenchmarkView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ChatRoomUIKitV2ViewController {
        ChatRoomUIKitV2ViewController()
    }

    func updateUIViewController(_ uiViewController: ChatRoomUIKitV2ViewController, context: Context) {}
}

enum ChatRoomV2MockMessageFactory {
    static let conversationID = "chat-room-v2-benchmark"
    static let currentUserID = "user-current"
    static let otherUserID = "user-bot"

    static func initialMessages(count: Int = 60) -> [RawMessage] {
        let start = 1_000
        return (0..<count).map { index in
            message(sequence: start + index)
        }
    }

    static func benchmarkMessages(count: Int = 1_000) -> [RawMessage] {
        (0..<count).map { index in
            message(sequence: index)
        }
    }

    static func historyPage(pageIndex: Int, pageSize: Int = 30) -> [RawMessage] {
        let pageStart = 1_000 - ((pageIndex + 1) * pageSize)
        guard pageStart >= 0 else { return [] }
        return (0..<pageSize).map { index in
            message(sequence: pageStart + index)
        }
    }

    private static func message(sequence: Int) -> RawMessage {
        let senderID = sequence.isMultiple(of: 3) ? currentUserID : otherUserID
        let text = textBody(sequence: sequence)
        return RawMessage(
            id: "mock-\(String(format: "%04d", sequence))",
            senderID: senderID,
            conversationID: conversationID,
            content: .text(text),
            createdAt: Date(timeIntervalSince1970: TimeInterval(sequence)),
            status: .complete,
            contentVersion: ChatRoomV2ContentHasher.hash(text)
        )
    }

    private static func textBody(sequence: Int) -> String {
        switch sequence % 6 {
        case 0:
            return "Short message \(sequence)."
        case 1:
            return "This is a medium length benchmark message \(sequence) that wraps onto multiple lines without changing after insertion."
        case 2:
            return "The V2 table keeps this text row deterministic. Message \(sequence) includes enough words to exercise measurement and scrolling."
        case 3:
            return "Plain text only for phase one. Historical pages are fully rendered before insertion. Sequence \(sequence)."
        case 4:
            return "Keyboard and pagination should not compete for scroll correction. This row is part of the fixed-height baseline \(sequence)."
        default:
            return "A longer text fixture \(sequence): " + Array(repeating: "stable geometry", count: 8).joined(separator: " ")
        }
    }
}
