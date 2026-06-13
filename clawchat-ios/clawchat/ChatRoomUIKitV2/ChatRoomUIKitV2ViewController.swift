import ChatLayout
import UIKit

@MainActor
final class ChatRoomUIKitV2ViewController: UIViewController {
    private let context: ChatContext
    private let fixture: ChatRoomV2Fixture
    private let usesFixtureData: Bool
    private let store = ChatMessageStoreV2()
    private let layoutCache = MessageLayoutCacheV2()
    private let mutationCoordinator = ChatMutationCoordinatorV2()
    private let diagnostics = ChatDiagnosticsV2()
    private lazy var renderCoordinator = MessageRenderCoordinatorV2(layoutCache: layoutCache)
    private let chatLayout = CollectionViewChatLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: chatLayout)
    private let diagnosticsLabel = UILabel()
    private var sourceMessagesByID: [String: Message] = [:]

    private let historyPageSize = 30
    private var isLoadingHistory = false
    private var hasAppeared = false
    private var hasPositionedInitialContent = false
    private var needsInitialBottomPosition = false
    private var isApplyingHistoryPrepend = false
    private var pendingKeyboardInset: CGFloat = 0
    private var hasInjectedKeyboardDuringPrepend = false
    private var lastScrollCommand = ChatListScrollCommand.none
    var bottomAutoScrollThreshold: CGFloat = 96
    var historyPreloadDistance: CGFloat = 0
    var onLoadOlder: (() -> Void)?
    var onNearBottomChange: ((Bool) -> Void)?
    var onUserScrollChange: ((Bool) -> Void)?
    var onInitialPositioned: (() -> Void)?
    var onPreviewImage: ((Message) -> Void)?
    var onSaveImage: ((Message) -> Void)?
    var onOpenDocument: ((UUID) -> Void)?
    var onContinueDocument: ((DocumentLinkPreview) -> Void)?
    var onTapList: (() -> Void)?
    private var isNearBottom = true

    init(context: ChatContext, fixture: ChatRoomV2Fixture = .textPrependStress) {
        self.context = context
        self.fixture = fixture
        self.usesFixtureData = true
        super.init(nibName: nil, bundle: nil)
    }

    init(context: ChatContext) {
        self.context = context
        self.fixture = .textPrependStress
        self.usesFixtureData = false
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDiagnosticsLabel()
        configureKeyboardObservers()
        if usesFixtureData {
            loadInitialFixture()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        positionInitialContentIfNeeded()
        guard !hasAppeared else { return }
        hasAppeared = true
        runAutoPrependStressIfNeeded()
        runAutoFixtureMutationsIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionInitialContentIfNeeded()
    }

    func applyLiveMessages(_ messages: [Message], currentUserID: String?) {
        guard !usesFixtureData else { return }
        let nextSourceMessagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let rawMessages = messages.enumerated().map { index, message in
            return ChatMessageV2(
                message: message,
                currentUserID: currentUserID,
                fallbackSequence: index,
                preservesSourceOrder: true,
                showsSenderInfo: context.isGroup,
                fallbackBotAvatarURLString: context.isGroup ? nil : context.avatarURLString
            )
        }
        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            self.sourceMessagesByID = nextSourceMessagesByID
            let rendered = self.renderCoordinator.renderPage(
                rawMessages,
                containerWidth: self.collectionWidth,
                traitCollection: self.traitCollection
            )
            self.applyRenderedMessagesInCurrentMutation(rendered, finish: finish)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        mutationCoordinator.enqueue { [weak self] finish in
            coordinator.animate { _ in
                self?.collectionView.collectionViewLayout.invalidateLayout()
            } completion: { [weak self] _ in
                self?.rerenderForCurrentWidth()
                finish()
            }
        }
    }

    func appendMockMessage() {
        let nextSequence = (store.messages.last?.sequence ?? 0) + 1
        let raw = ChatMessageV2(
            id: "v2-message-\(nextSequence)",
            sequence: nextSequence,
            text: "#\(nextSequence) Appended text-only V2 message.",
            isOutgoing: true
        )
        let rendered = renderCoordinator.render(raw, containerWidth: collectionWidth, traitCollection: traitCollection)
        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            let indexPath = IndexPath(item: self.store.count, section: 0)
            self.store.append(rendered)
            self.diagnostics.recordAppend()
            self.collectionView.performBatchUpdates {
                self.collectionView.insertItems(at: [indexPath])
            } completion: { [weak self] _ in
                self?.updateDiagnosticsLabel()
                finish()
            }
        }
    }

    private func configureCollectionView() {
        view.backgroundColor = .systemBackground
        chatLayout.keepContentAtBottomOfVisibleArea = true
        chatLayout.keepContentOffsetAtBottomOnBatchUpdates = true
        chatLayout.processOnlyVisibleItemsOnAnimatedBatchUpdates = true
        if #available(iOS 16.0, *) {
            chatLayout.supportSelfSizingInvalidation = false
        }
        chatLayout.delegate = self

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TextMessageCollectionViewCell.self, forCellWithReuseIdentifier: TextMessageCollectionViewCell.reuseIdentifier)
        collectionView.accessibilityIdentifier = "chatRoomV2.collectionView"
        let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(collectionViewTapped(_:)))
        tapRecognizer.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tapRecognizer)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureDiagnosticsLabel() {
        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        diagnosticsLabel.textColor = .secondaryLabel
        diagnosticsLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.82)
        diagnosticsLabel.numberOfLines = 2
        diagnosticsLabel.accessibilityIdentifier = "chatRoomV2.diagnostics"
        diagnosticsLabel.isAccessibilityElement = true
        diagnosticsLabel.text = diagnostics.summary(messageCount: store.count)
        view.addSubview(diagnosticsLabel)
        NSLayoutConstraint.activate([
            diagnosticsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            diagnosticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            diagnosticsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])
    }

    private func configureKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    private func loadInitialFixture() {
        let rawMessages: [ChatMessageV2]
        switch fixture {
        case .textPrependStress:
            rawMessages = ChatRoomV2FixtureFactory.initialTextMessages()
        case .textBenchmark:
            rawMessages = ChatRoomV2FixtureFactory.benchmarkMessages()
        case .richMedia:
            rawMessages = ChatRoomV2FixtureFactory.richMediaMessages()
        }

        let rendered = renderCoordinator.renderPage(rawMessages, containerWidth: collectionWidth, traitCollection: traitCollection)
        store.initialLoad(rendered)
        collectionView.reloadData()
        diagnostics.recordInitialReload()
        needsInitialBottomPosition = true
        positionInitialContentIfNeeded()
        updateDiagnosticsLabel()
    }

    func applyScrollCommand(_ command: ChatListScrollCommand) {
        guard command != lastScrollCommand else { return }
        lastScrollCommand = command
        switch command.kind {
        case .none:
            return
        case .scrollToBottom(let animated):
            scrollToBottomThroughMutationQueue(animated: animated)
        }
    }

    private func loadPreviousPageIfNeeded(completion: (() -> Void)? = nil) {
        guard usesFixtureData else {
            onLoadOlder?()
            completion?()
            return
        }
        guard !isLoadingHistory else {
            completion?()
            return
        }
        guard let earliestSequence = store.earliestSequence, earliestSequence > 1 else {
            completion?()
            return
        }
        isLoadingHistory = true
        let rawPage = ChatRoomV2FixtureFactory.historyPage(before: earliestSequence, count: historyPageSize)
        let renderedPage = renderCoordinator.renderPage(rawPage, containerWidth: collectionWidth, traitCollection: traitCollection)
        prependRenderedHistory(renderedPage, completion: completion)
    }

    private func prependRenderedHistory(_ page: [RenderedMessageV2], completion: (() -> Void)? = nil) {
        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            self.prependRenderedHistoryInCurrentMutation(page, finish: finish, completion: completion)
        }
    }

    private func prependRenderedHistoryInCurrentMutation(
        _ page: [RenderedMessageV2],
        finish: @escaping ChatMutationCoordinatorV2.Finish,
        completion: (() -> Void)? = nil
    ) {
        guard !page.isEmpty else {
            isLoadingHistory = false
            finish()
            completion?()
            return
        }

        self.collectionView.layoutIfNeeded()
        let snapshot = self.chatLayout.getContentOffsetSnapshot(from: .top)
        let anchorBefore = self.visibleAnchor()
        let insertedIndexPaths = page.indices.map { IndexPath(item: $0, section: 0) }
        self.store.prependHistory(page)
        let restoredSnapshot = snapshot.map { snapshot in
            ChatLayoutPositionSnapshot(
                indexPath: IndexPath(item: snapshot.indexPath.item + page.count, section: snapshot.indexPath.section),
                edge: snapshot.edge,
                offset: snapshot.offset
            )
        }
        self.diagnostics.recordPrepend()
        self.isApplyingHistoryPrepend = true
        self.injectKeyboardNotificationDuringPrependIfNeeded()
        self.collectionView.performBatchUpdates {
            self.collectionView.insertItems(at: insertedIndexPaths)
        } completion: { [weak self] _ in
            guard let self else {
                finish()
                return
            }
            self.isApplyingHistoryPrepend = false
            if let restoredSnapshot {
                self.chatLayout.restoreContentOffset(with: restoredSnapshot)
                self.diagnostics.recordRestore()
            }
            self.collectionView.layoutIfNeeded()
            if let anchorBefore, let anchorAfter = self.visibleAnchor(messageID: anchorBefore.messageID) {
                self.diagnostics.recordAnchorDrift(anchorAfter.offsetFromVisibleTop - anchorBefore.offsetFromVisibleTop)
            }
            self.isLoadingHistory = false
            self.updateDiagnosticsLabel()
            finish()
            completion?()
        }
    }

    private func runAutoPrependStressIfNeeded() {
        let count = ChatRoomV2FeatureFlag.autoPrependStressCount
        guard count > 0 else { return }
        runPrependStress(remaining: count)
    }

    private func runPrependStress(remaining: Int) {
        guard remaining > 0 else { return }
        loadPreviousPageIfNeeded { [weak self] in
            self?.runPrependStress(remaining: remaining - 1)
        }
    }

    private func runAutoFixtureMutationsIfNeeded() {
        guard usesFixtureData else { return }
        if ChatRoomV2FeatureFlag.autoRapidSnapshotBurst {
            runAutoRapidSnapshotBurst()
        }
        if ChatRoomV2FeatureFlag.autoSameIDUpdate {
            runAutoSameIDUpdate()
        }
        if ChatRoomV2FeatureFlag.autoWindowReplace {
            runAutoWindowReplace()
        }
        if ChatRoomV2FeatureFlag.autoKeyboardShowHide {
            runAutoKeyboardShowHide()
        }
    }

    private func runAutoSameIDUpdate() {
        let raw = store.messages.map { message in
            ChatMessageV2(
                id: message.id,
                sequence: message.sequence,
                isOutgoing: message.isOutgoing,
                blocks: message.id == store.messages.first?.id
                    ? message.blocks + [
                        .text(TextBlockContentV2(
                            id: "\(message.id)-text-debug-update",
                            text: "Updated in place without reloadData.",
                            isMarkdown: false
                        ))
                    ]
                    : message.blocks,
                sender: message.sender,
                status: message.status
            )
        }
        let rendered = renderCoordinator.renderPage(raw, containerWidth: collectionWidth, traitCollection: traitCollection)
        applyRenderedMessages(rendered)
    }

    private func runAutoRapidSnapshotBurst() {
        let base = store.messages.map { message in
            ChatMessageV2(
                id: message.id,
                sequence: message.sequence,
                isOutgoing: message.isOutgoing,
                blocks: message.blocks,
                sender: message.sender,
                status: message.status
            )
        }
        guard let lastSequence = base.last?.sequence else { return }

        let firstAppend = ChatMessageV2(
            id: "v2-burst-\(lastSequence + 1)",
            sequence: lastSequence + 1,
            text: "Burst snapshot append one.",
            isOutgoing: true
        )
        let secondAppend = ChatMessageV2(
            id: "v2-burst-\(lastSequence + 2)",
            sequence: lastSequence + 2,
            text: "Burst snapshot append two.",
            isOutgoing: false
        )
        let prepended = ChatMessageV2(
            id: "v2-burst-\(lastSequence - base.count)",
            sequence: lastSequence - base.count,
            text: "Burst snapshot prepended history row.",
            isOutgoing: false
        )

        let snapshots = [
            base + [firstAppend],
            base + [firstAppend, secondAppend],
            [prepended] + base + [firstAppend, secondAppend]
        ]

        for snapshot in snapshots {
            let rendered = renderCoordinator.renderPage(snapshot, containerWidth: collectionWidth, traitCollection: traitCollection)
            applyRenderedMessages(rendered)
        }
    }

    private func runAutoWindowReplace() {
        let raw = ChatRoomV2FixtureFactory.initialTextMessages(count: 60, newestSequence: 2_000)
        let rendered = renderCoordinator.renderPage(raw, containerWidth: collectionWidth, traitCollection: traitCollection)
        applyRenderedMessages(rendered)
    }

    private func runAutoKeyboardShowHide() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.postKeyboardFrame(minY: max(0, self.view.bounds.height - 280), height: 280)
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.postKeyboardFrame(minY: self.view.bounds.height, height: 0)
        }
    }

    private func rerenderForCurrentWidth() {
        let rawMessages = store.messages.map {
            ChatMessageV2(
                id: $0.id,
                sequence: $0.sequence,
                isOutgoing: $0.isOutgoing,
                blocks: $0.blocks,
                sender: $0.sender,
                status: $0.status
            )
        }
        let rendered = renderCoordinator.renderPage(rawMessages, containerWidth: collectionWidth, traitCollection: traitCollection)
        store.replaceAll(rendered)
        collectionView.collectionViewLayout.invalidateLayout()
        updateDiagnosticsLabel()
    }

    private func applyRenderedMessages(_ rendered: [RenderedMessageV2]) {
        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            self.applyRenderedMessagesInCurrentMutation(rendered, finish: finish)
        }
    }

    private func applyRenderedMessagesInCurrentMutation(
        _ rendered: [RenderedMessageV2],
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        let normalizedRendered = ChatMessageStoreV2.normalized(rendered)
        let previousIDs = store.messages.map(\.id)
        let nextIDs = normalizedRendered.map(\.id)
        guard previousIDs != nextIDs || store.messages != normalizedRendered else {
            finish()
            return
        }

        guard !normalizedRendered.isEmpty else {
            deleteAllRenderedMessagesInCurrentMutation(finish: finish)
            return
        }

        if store.count == 0 {
            store.initialLoad(normalizedRendered)
            collectionView.reloadData()
            diagnostics.recordInitialReload()
            needsInitialBottomPosition = true
            positionInitialContentIfNeeded()
            updateDiagnosticsLabel()
            finish()
            return
        }

        if previousIDs == nextIDs {
            updateRenderedMessagesInCurrentMutation(normalizedRendered, finish: finish)
            return
        }

        if let contiguousChange = contiguousChange(previousIDs: previousIDs, nextIDs: nextIDs) {
            applyContiguousChangeInCurrentMutation(normalizedRendered, change: contiguousChange, finish: finish)
            return
        }

        if let prependCount = prependedRowCount(previousIDs: previousIDs, nextIDs: nextIDs), prependCount > 0 {
            prependRenderedHistoryInCurrentMutation(Array(normalizedRendered.prefix(prependCount)), finish: finish)
            return
        }

        if let appendStart = appendedRowStart(previousIDs: previousIDs, nextIDs: nextIDs) {
            appendRenderedMessagesInCurrentMutation(Array(normalizedRendered[appendStart...]), finish: finish)
            return
        }

        replaceRenderedMessagesInCurrentMutation(normalizedRendered, finish: finish)
    }

    private func updateRenderedMessagesInCurrentMutation(
        _ rendered: [RenderedMessageV2],
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        let changedIndexPaths = rendered.indices.compactMap { index -> IndexPath? in
            guard store.messages.indices.contains(index), store.messages[index] != rendered[index] else {
                return nil
            }
            return IndexPath(item: index, section: 0)
        }
        guard !changedIndexPaths.isEmpty else {
            finish()
            return
        }

        self.collectionView.layoutIfNeeded()
        let snapshot = self.chatLayout.getContentOffsetSnapshot(from: .top)
        self.store.replaceAll(rendered)
        self.collectionView.performBatchUpdates {
            self.collectionView.reloadItems(at: changedIndexPaths)
        } completion: { [weak self] _ in
            guard let self else {
                finish()
                return
            }
            if let snapshot {
                self.chatLayout.restoreContentOffset(with: snapshot)
                self.diagnostics.recordRestore()
            }
            self.updateDiagnosticsLabel()
            finish()
        }
    }

    private func deleteAllRenderedMessagesInCurrentMutation(
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        guard store.count > 0 else {
            finish()
            return
        }
        let indexPaths = self.store.messages.indices.map { IndexPath(item: $0, section: 0) }
        self.store.replaceAll([])
        self.collectionView.performBatchUpdates {
            self.collectionView.deleteItems(at: indexPaths)
        } completion: { [weak self] _ in
            self?.updateDiagnosticsLabel()
            finish()
        }
    }

    private func replaceRenderedMessagesInCurrentMutation(
        _ rendered: [RenderedMessageV2],
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        let oldIndexPaths = self.store.messages.indices.map { IndexPath(item: $0, section: 0) }
        let newIndexPaths = rendered.indices.map { IndexPath(item: $0, section: 0) }
        self.store.replaceAll(rendered)
        self.collectionView.performBatchUpdates {
            if !oldIndexPaths.isEmpty {
                self.collectionView.deleteItems(at: oldIndexPaths)
            }
            if !newIndexPaths.isEmpty {
                self.collectionView.insertItems(at: newIndexPaths)
            }
        } completion: { [weak self] _ in
            if self?.isNearBottom == true {
                self?.scrollToBottom(animated: false)
            }
            self?.updateDiagnosticsLabel()
            finish()
        }
    }

    private struct ContiguousChange {
        let prependCount: Int
        let appendStart: Int
    }

    private func contiguousChange(previousIDs: [String], nextIDs: [String]) -> ContiguousChange? {
        guard !previousIDs.isEmpty,
              let previousStart = nextIDs.firstIndex(of: previousIDs[0]),
              previousStart + previousIDs.count <= nextIDs.count,
              Array(nextIDs[previousStart..<(previousStart + previousIDs.count)]) == previousIDs
        else {
            return nil
        }
        guard previousStart > 0 || nextIDs.count > previousStart + previousIDs.count else {
            return nil
        }
        return ContiguousChange(
            prependCount: previousStart,
            appendStart: previousStart + previousIDs.count
        )
    }

    private func applyContiguousChangeInCurrentMutation(
        _ rendered: [RenderedMessageV2],
        change: ContiguousChange,
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        let prepended = change.prependCount > 0 ? Array(rendered.prefix(change.prependCount)) : []
        let appended = change.appendStart < rendered.count ? Array(rendered[change.appendStart...]) : []
        guard !prepended.isEmpty || !appended.isEmpty else {
            finish()
            return
        }

        self.collectionView.layoutIfNeeded()
        let snapshot = self.chatLayout.getContentOffsetSnapshot(from: .top)
        let oldCount = self.store.count
        let prependIndexPaths = prepended.indices.map { IndexPath(item: $0, section: 0) }
        let appendIndexPaths = appended.indices.map { IndexPath(item: oldCount + change.prependCount + $0, section: 0) }
        self.store.replaceAll(rendered)
        let restoredSnapshot = snapshot.map { snapshot in
            ChatLayoutPositionSnapshot(
                indexPath: IndexPath(item: snapshot.indexPath.item + change.prependCount, section: snapshot.indexPath.section),
                edge: snapshot.edge,
                offset: snapshot.offset
            )
        }

        if change.prependCount > 0 {
            self.diagnostics.recordPrepend()
        }
        if !appended.isEmpty {
            self.diagnostics.recordAppend()
        }

        self.collectionView.performBatchUpdates {
            if !prependIndexPaths.isEmpty {
                self.collectionView.insertItems(at: prependIndexPaths)
            }
            if !appendIndexPaths.isEmpty {
                self.collectionView.insertItems(at: appendIndexPaths)
            }
        } completion: { [weak self] _ in
            guard let self else {
                finish()
                return
            }
            if let restoredSnapshot, change.prependCount > 0 {
                self.chatLayout.restoreContentOffset(with: restoredSnapshot)
                self.diagnostics.recordRestore()
            } else if self.isNearBottom {
                self.scrollToBottom(animated: false)
            }
            self.updateDiagnosticsLabel()
            finish()
        }
    }

    private func appendRenderedMessagesInCurrentMutation(
        _ messages: [RenderedMessageV2],
        finish: @escaping ChatMutationCoordinatorV2.Finish
    ) {
        guard !messages.isEmpty else {
            finish()
            return
        }
        let start = self.store.count
        let indexPaths = messages.indices.map { IndexPath(item: start + $0, section: 0) }
        messages.forEach { self.store.append($0) }
        self.diagnostics.recordAppend()
        self.collectionView.performBatchUpdates {
            self.collectionView.insertItems(at: indexPaths)
        } completion: { [weak self] _ in
            if self?.isNearBottom == true {
                self?.scrollToBottom(animated: false)
            }
            self?.updateDiagnosticsLabel()
            finish()
        }
    }

    private func prependedRowCount(previousIDs: [String], nextIDs: [String]) -> Int? {
        guard let previousFirstID = previousIDs.first,
              let previousStart = nextIDs.firstIndex(of: previousFirstID),
              previousStart > 0,
              nextIDs.count == previousStart + previousIDs.count,
              Array(nextIDs[previousStart...]) == previousIDs
        else {
            return nil
        }
        return previousStart
    }

    private func appendedRowStart(previousIDs: [String], nextIDs: [String]) -> Int? {
        guard nextIDs.count > previousIDs.count,
              Array(nextIDs.prefix(previousIDs.count)) == previousIDs
        else {
            return nil
        }
        return previousIDs.count
    }

    private func scrollToBottomThroughMutationQueue(animated: Bool) {
        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            self.scrollToBottom(animated: animated)
            finish()
        }
    }

    @discardableResult
    private func scrollToBottom(animated: Bool) -> Bool {
        guard store.count > 0, isReadyForScrolling else { return false }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(
            at: IndexPath(item: store.count - 1, section: 0),
            at: .bottom,
            animated: animated
        )
        return true
    }

    private func positionInitialContentIfNeeded() {
        guard needsInitialBottomPosition,
              isViewLoaded,
              collectionView.bounds.width > 0,
              collectionView.bounds.height > 0,
              store.count > 0
        else {
            return
        }
        needsInitialBottomPosition = false
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        guard scrollToBottom(animated: false) else {
            needsInitialBottomPosition = true
            return
        }
        collectionView.layoutIfNeeded()
        if !hasPositionedInitialContent {
            hasPositionedInitialContent = true
            onInitialPositioned?()
        }
    }

    private var isReadyForScrolling: Bool {
        collectionView.window != nil && collectionView.bounds.width > 0 && collectionView.bounds.height > 0
    }

    private func visibleAnchor() -> VisibleMessageAnchorV2? {
        guard let indexPath = collectionView.indexPathsForVisibleItems.sorted().first else {
            return nil
        }
        return visibleAnchor(at: indexPath)
    }

    private func visibleAnchor(messageID: String) -> VisibleMessageAnchorV2? {
        guard let row = store.firstIndex(messageID: messageID) else { return nil }
        return visibleAnchor(at: IndexPath(item: row, section: 0))
    }

    private func visibleAnchor(at indexPath: IndexPath) -> VisibleMessageAnchorV2? {
        guard let message = store.message(at: indexPath),
              let attributes = collectionView.layoutAttributesForItem(at: indexPath)
        else {
            return nil
        }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return VisibleMessageAnchorV2(
            messageID: message.id,
            offsetFromVisibleTop: attributes.frame.minY - visibleTop
        )
    }

    private var collectionWidth: CGFloat {
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width
        return max(width, 320)
    }

    private func updateDiagnosticsLabel() {
        diagnosticsLabel.text = diagnostics.summary(messageCount: store.count)
        diagnosticsLabel.accessibilityValue = diagnosticsLabel.text
        diagnosticsLabel.isHidden = !usesFixtureData && !ChatRoomV2FeatureFlag.showsDiagnostics
    }

    @objc
    private func keyboardWillChangeFrame(_ notification: Notification) {
        let keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        let convertedFrame = view.convert(keyboardFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - convertedFrame.minY)
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRawValue = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        let animationOptions = UIView.AnimationOptions(rawValue: curveRawValue << 16)
        pendingKeyboardInset = overlap

        mutationCoordinator.enqueue { [weak self] finish in
            guard let self else {
                finish()
                return
            }
            if self.isApplyingHistoryPrepend {
                self.diagnostics.recordKeyboardInsetDuringPrepend()
            }
            self.collectionView.layoutIfNeeded()
            let snapshot = self.chatLayout.getContentOffsetSnapshot(from: .bottom)
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [animationOptions, .beginFromCurrentState]
            ) {
                self.collectionView.contentInset.bottom = self.pendingKeyboardInset
                self.collectionView.verticalScrollIndicatorInsets.bottom = self.pendingKeyboardInset
                self.collectionView.layoutIfNeeded()
            } completion: { [weak self] _ in
                guard let self else {
                    finish()
                    return
                }
                if let snapshot {
                    self.chatLayout.restoreContentOffset(with: snapshot)
                    self.diagnostics.recordKeyboardRestore()
                }
                self.updateNearBottom(self.collectionView)
                self.updateDiagnosticsLabel()
                finish()
            }
        }
    }

    private func injectKeyboardNotificationDuringPrependIfNeeded() {
        guard usesFixtureData,
              ChatRoomV2FeatureFlag.autoKeyboardDuringPrepend,
              !hasInjectedKeyboardDuringPrepend
        else {
            return
        }
        hasInjectedKeyboardDuringPrepend = true
        let keyboardHeight: CGFloat = 260
        postKeyboardFrame(minY: max(0, view.bounds.height - keyboardHeight), height: keyboardHeight)
    }

    private func postKeyboardFrame(minY: CGFloat, height: CGFloat) {
        let keyboardFrame = CGRect(
            x: 0,
            y: minY,
            width: max(view.bounds.width, collectionWidth),
            height: height
        )
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboardFrame),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.0)
            ]
        )
    }

    @objc
    private func collectionViewTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onTapList?()
    }
}

extension ChatRoomUIKitV2ViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        store.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextMessageCollectionViewCell.reuseIdentifier,
            for: indexPath
        )
        guard let textCell = cell as? TextMessageCollectionViewCell,
              let message = store.message(at: indexPath)
        else {
            return cell
        }
        textCell.configure(with: message)
        textCell.onImageTap = { [weak self] blockID in
            self?.previewImage(messageID: message.id, blockID: blockID)
        }
        textCell.onDocumentTap = { [weak self] documentID in
            self?.onOpenDocument?(documentID)
        }
        textCell.onDocumentContinueTap = { [weak self] preview in
            self?.onContinueDocument?(preview)
        }
        return textCell
    }
}

extension ChatRoomUIKitV2ViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasAppeared else { return }
        updateNearBottom(scrollView)
        let distanceFromTop = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let threshold = max(historyPreloadDistance, scrollView.bounds.height * 2.2, 1)
        guard distanceFromTop <= threshold else { return }
        loadPreviousPageIfNeeded()
    }

    private func updateNearBottom(_ scrollView: UIScrollView) {
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
        let distanceFromBottom = scrollView.contentSize.height - visibleBottom
        let nextIsNearBottom = distanceFromBottom <= bottomAutoScrollThreshold
        guard nextIsNearBottom != isNearBottom else { return }
        isNearBottom = nextIsNearBottom
        onNearBottomChange?(nextIsNearBottom)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onUserScrollChange?(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            onUserScrollChange?(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onUserScrollChange?(false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let message = store.message(at: indexPath) else {
            return
        }
        if let document = message.blocks.compactMap({ block -> DocumentLinkBlockContentV2? in
            if case .document(let document) = block {
                return document
            }
            return nil
        }).first {
            onOpenDocument?(document.preview.id)
            return
        }

        guard message.blocks.contains(where: { block in
            if case .image = block {
                return true
            }
            return false
        }) else { return }
        previewImage(messageID: message.id)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let message = store.message(at: indexPath) else { return nil }
        let sourceMessage = sourceMessagesByID[message.id]
        let identifier = message.id as NSString

        return UIContextMenuConfiguration(identifier: identifier, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []

            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                actions.append(UIAction(title: "复制消息", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                })
            }

            if let sourceMessage,
               message.blocks.contains(where: { block in
                   if case .image = block { return true }
                   return false
               }) {
                actions.append(UIAction(title: "保存图片", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                    self?.onSaveImage?(sourceMessage)
                })
            }

            guard !actions.isEmpty else { return nil }
            return UIMenu(children: actions)
        }
    }

    private func previewImage(messageID: String, blockID: String? = nil) {
        if let message = sourceMessagesByID[messageID] {
            onPreviewImage?(message)
            return
        }
        guard let fallback = previewMessageFromRenderedImage(messageID: messageID, blockID: blockID) else { return }
        onPreviewImage?(fallback)
    }

    private func previewMessageFromRenderedImage(messageID: String, blockID: String?) -> Message? {
        guard let rendered = store.messages.first(where: { $0.id == messageID }),
              let imageBlock = rendered.blocks.compactMap({ block -> ImageBlockContentV2? in
                  if case .image(let image) = block {
                      return image
                  }
                  return nil
              }).first(where: { image in
                  blockID == nil || image.id == blockID
              })
        else {
            return nil
        }

        let content = RealtimeContentPayload(
            type: "image",
            body: nil,
            url: imageBlock.urlString,
            name: imageBlock.name,
            size: nil,
            meta: [
                "width": AnyCodable(Int(imageBlock.aspectRatio * 1000)),
                "height": AnyCodable(1000)
            ]
        )
        let payload = RealtimeMessagePayload(
            id: rendered.id,
            topic: context.id,
            conversationId: context.id,
            timestamp: Int64(Date().timeIntervalSince1970),
            from: MessagePeerPayload(type: rendered.isOutgoing ? "user" : "bot", id: rendered.isOutgoing ? "current-user" : "bot", name: nil, avatar: nil),
            to: MessagePeerPayload(type: rendered.isOutgoing ? "bot" : "user", id: rendered.isOutgoing ? "bot" : "current-user", name: nil, avatar: nil),
            content: content,
            seq: Int64(rendered.sequence)
        )
        return Message(from: payload)
    }
}

extension ChatRoomUIKitV2ViewController: ChatLayoutDelegate {
    func sizeForItem(_ chatLayout: CollectionViewChatLayout, at indexPath: IndexPath) -> ItemSize {
        guard let message = store.message(at: indexPath) else {
            return .exact(CGSize(width: collectionWidth, height: 44))
        }
        return .exact(message.layout.itemSize)
    }

    func alignmentForItem(_ chatLayout: CollectionViewChatLayout, at indexPath: IndexPath) -> ChatItemAlignment {
        .fullWidth
    }

    func interItemSpacing(_ chatLayout: CollectionViewChatLayout, after indexPath: IndexPath) -> CGFloat? {
        0
    }
}
