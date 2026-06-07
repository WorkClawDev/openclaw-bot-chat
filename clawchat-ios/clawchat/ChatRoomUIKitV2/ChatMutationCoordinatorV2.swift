import Foundation

@MainActor
final class ChatMutationCoordinatorV2 {
    typealias Finish = () -> Void
    typealias Mutation = (@escaping Finish) -> Void

    private var isApplyingMutation = false
    private var pendingMutations: [Mutation] = []

    var isBusy: Bool {
        isApplyingMutation
    }

    var pendingCount: Int {
        pendingMutations.count
    }

    func enqueue(_ mutation: @escaping Mutation) {
        pendingMutations.append(mutation)
        drain()
    }

    private func drain() {
        guard !isApplyingMutation, !pendingMutations.isEmpty else { return }
        isApplyingMutation = true
        let mutation = pendingMutations.removeFirst()
        mutation { [weak self] in
            guard let self else { return }
            self.isApplyingMutation = false
            self.drain()
        }
    }
}
