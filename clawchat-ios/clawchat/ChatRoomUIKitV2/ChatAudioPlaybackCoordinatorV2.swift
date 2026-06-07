import AVFoundation
import CryptoKit
import Foundation

@MainActor
struct ChatAudioPlaybackStateV2: Equatable {
    var playingBlockID: String?
    var loadingBlockID: String?
    var failedBlockID: String?

    static let idle = ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: nil, failedBlockID: nil)
}

@MainActor
final class ChatAudioPlaybackCoordinatorV2 {
    typealias Observer = (ChatAudioPlaybackStateV2) -> Void

    static let shared = ChatAudioPlaybackCoordinatorV2()

    private var player: AVPlayer?
    private var currentBlockID: String?
    private var prepareTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var observers: [UUID: Observer] = [:]
    private(set) var state = ChatAudioPlaybackStateV2.idle

    func addObserver(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(state)
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    func toggle(block: AudioBlockContentV2) {
        guard let urlString = block.urlString,
              APIClient.shared.resolvedURL(from: urlString) != nil
        else {
            stop()
            publish(ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: nil, failedBlockID: block.id))
            return
        }

        if currentBlockID == block.id,
           state.playingBlockID == block.id || state.loadingBlockID == block.id {
            stop()
            return
        }

        stop()
        currentBlockID = block.id
        publish(ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: block.id, failedBlockID: nil))
        prepareTask = Task { [weak self] in
            guard let playableURL = await LocalAudioStoreV2.shared.ensureCachedAudio(
                for: block.cacheContent,
                fallbackIdentifier: block.id
            ) else {
                await MainActor.run {
                    guard self?.currentBlockID == block.id else { return }
                    self?.publish(ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: nil, failedBlockID: block.id))
                }
                return
            }

            await MainActor.run {
                guard self?.currentBlockID == block.id else { return }
                self?.startPlayer(blockID: block.id, url: playableURL)
            }
        }
    }

    private func startPlayer(blockID: String, url: URL) {
        removeEndObserver()
        statusObservation = nil
        timeControlObservation = nil
        currentBlockID = blockID
        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard self?.currentBlockID == blockID else { return }
                if item.status == .failed {
                    self?.publish(ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: nil, failedBlockID: blockID))
                }
            }
        }
        timeControlObservation = nextPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard self?.currentBlockID == blockID else { return }
                switch player.timeControlStatus {
                case .playing:
                    self?.publish(ChatAudioPlaybackStateV2(playingBlockID: blockID, loadingBlockID: nil, failedBlockID: nil))
                case .waitingToPlayAtSpecifiedRate:
                    self?.publish(ChatAudioPlaybackStateV2(playingBlockID: nil, loadingBlockID: blockID, failedBlockID: nil))
                case .paused:
                    break
                @unknown default:
                    break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
        nextPlayer.play()
    }

    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        player?.pause()
        player = nil
        currentBlockID = nil
        statusObservation = nil
        timeControlObservation = nil
        removeEndObserver()
        publish(.idle)
    }

    private func publish(_ nextState: ChatAudioPlaybackStateV2) {
        state = nextState
        observers.values.forEach { $0(nextState) }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

private final class LocalAudioStoreV2 {
    static let shared = LocalAudioStoreV2()

    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "site.changer.clawchat.local-audio-store-v2")
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let baseURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        directoryURL = baseURL
            .appendingPathComponent("clawchat", isDirectory: true)
            .appendingPathComponent("audio-cache", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    func ensureCachedAudio(for content: MessageContent, fallbackIdentifier: String) async -> URL? {
        guard let rawURLString = content.audioURLString,
              let remoteURL = APIClient.shared.resolvedURL(from: rawURLString)
        else {
            return nil
        }

        if remoteURL.isFileURL {
            return fileManager.fileExists(atPath: remoteURL.path) ? remoteURL : nil
        }

        if let cachedURL = cachedFileURL(for: content, fallbackIdentifier: fallbackIdentifier) {
            return cachedURL
        }

        do {
            let data = try await APIClient.shared.fetchRemoteData(from: remoteURL, acceptHeader: "audio/*,*/*;q=0.8")
            return cacheAudioData(data, for: content, fallbackIdentifier: fallbackIdentifier)
        } catch {
            return nil
        }
    }

    private func cachedFileURL(for content: MessageContent, fallbackIdentifier: String) -> URL? {
        guard let fileURL = storageFileURL(for: content, fallbackIdentifier: fallbackIdentifier) else {
            return nil
        }
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    @discardableResult
    private func cacheAudioData(_ data: Data, for content: MessageContent, fallbackIdentifier: String) -> URL? {
        guard !data.isEmpty,
              let fileURL = storageFileURL(for: content, fallbackIdentifier: fallbackIdentifier)
        else {
            return nil
        }

        queue.sync {
            if !fileManager.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func storageFileURL(for content: MessageContent, fallbackIdentifier: String) -> URL? {
        let identity = content.mediaCacheSignatureV2.isEmpty ? fallbackIdentifier : content.mediaCacheSignatureV2
        guard !identity.isEmpty else { return nil }
        return directoryURL.appendingPathComponent("\(digest(identity)).\(fileExtension(for: content))")
    }

    private func fileExtension(for content: MessageContent) -> String {
        if let pathExtension = APIClient.shared.resolvedURL(from: content.audioURLString)?.pathExtension,
           !pathExtension.isEmpty {
            return pathExtension
        }
        if let mimeType = content.asset?.mimeType?.lowercased() {
            if mimeType.contains("mpeg") || mimeType.contains("mp3") { return "mp3" }
            if mimeType.contains("wav") { return "wav" }
            if mimeType.contains("ogg") { return "ogg" }
        }
        return "m4a"
    }

    private func digest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
