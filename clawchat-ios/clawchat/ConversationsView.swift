import SwiftUI
import Combine

class ConversationsViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: LocalMessageStore.conversationsDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadCachedConversations()
            }
            .store(in: &cancellables)
    }

    func fetchConversations() {
        errorMessage = nil
        reloadCachedConversations()
        isLoading = false

        APIClient.shared.fetchConversations()
            .receive(on: DispatchQueue.main)
            .sink { completion in
                self.isLoading = false
                if case .failure(let error) = completion {
                    self.errorMessage = error.localizedDescription
                }
            } receiveValue: { (conversations: [Conversation]) in
                LocalMessageStore.shared.upsert(conversations: conversations)
                self.conversations = self.sortConversations(conversations)
            }
            .store(in: &cancellables)
    }

    private func reloadCachedConversations() {
        conversations = sortConversations(LocalMessageStore.shared.cachedConversations())
    }

    private func sortConversations(_ items: [Conversation]) -> [Conversation] {
        items.sorted { lhs, rhs in
            let leftTimestamp = lhs.lastMessage?.timestamp ?? Int64.min
            let rightTimestamp = rhs.lastMessage?.timestamp ?? Int64.min
            if leftTimestamp != rightTimestamp {
                return leftTimestamp > rightTimestamp
            }
            return lhs.id < rhs.id
        }
    }
}

struct ConversationsView: View {
    @StateObject private var viewModel = ConversationsViewModel()

    var body: some View {
        NavigationView {
            List(viewModel.conversations) { conversation in
                NavigationLink(destination: ChatRoomView(conversationId: conversation.id, title: conversation.name)) {
                    ConversationRow(conversation: conversation)
                }
            }
            .navigationTitle("Chats")
            .onAppear {
                viewModel.fetchConversations()
            }
            .refreshable {
                viewModel.fetchConversations()
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    private var lastMessageTimestamp: String? {
        guard let date = conversation.lastMessage?.displayDate else {
            return nil
        }

        if Calendar.current.isDateInToday(date) {
            return ConversationRow.timeFormatter.string(from: date)
        }

        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            return ConversationRow.dayFormatter.string(from: date)
        }

        return ConversationRow.yearFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    var body: some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .resizable()
                .frame(width: 40, height: 40)
                .foregroundColor(.gray)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.name)
                        .font(.headline)

                    Spacer(minLength: 8)

                    if let lastMessageTimestamp {
                        Text(lastMessageTimestamp)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }

                if let lastMsg = conversation.lastMessage?.content {
                    Text(lastMsg)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }

            if let count = conversation.unreadCount, count > 0 {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundColor(.white)
                    )
            }
        }
        .padding(.vertical, 4)
    }
}
