import Foundation

@MainActor
final class ChatMutationCoordinatorV2 {
    typealias Finish = () -> Void
    typealias Mutation = (@escaping Finish) -> Void

    enum CoalescingKey: Hashable {
        case liveSnapshot
        case liveHistoryState
        case layoutContext
        case scrollCommand
    }

    private struct PendingMutation {
        let coalescingKey: CoalescingKey?
        let mutation: Mutation
    }

    private var isApplyingMutation = false
    private var pendingMutations: [PendingMutation] = []

    var isBusy: Bool {
        isApplyingMutation
    }

    var pendingCount: Int {
        pendingMutations.count
    }

    func enqueue(_ mutation: @escaping Mutation) {
        pendingMutations.append(PendingMutation(coalescingKey: nil, mutation: mutation))
        drain()
    }

    /// Keeps at most one pending mutation for `key`. An in-flight mutation is
    /// allowed to finish, while any older pending value is discarded so the
    /// newest state is applied in chronological order after unrelated work.
    func enqueueLatest(for key: CoalescingKey, _ mutation: @escaping Mutation) {
        pendingMutations.removeAll { $0.coalescingKey == key }
        pendingMutations.append(PendingMutation(coalescingKey: key, mutation: mutation))
        drain()
    }

    private func drain() {
        guard !isApplyingMutation, !pendingMutations.isEmpty else { return }
        isApplyingMutation = true
        let pendingMutation = pendingMutations.removeFirst()
        pendingMutation.mutation { [weak self] in
            guard let self else { return }
            self.isApplyingMutation = false
            self.drain()
        }
    }
}
