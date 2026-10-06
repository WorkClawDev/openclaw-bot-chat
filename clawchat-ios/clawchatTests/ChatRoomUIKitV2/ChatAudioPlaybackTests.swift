import Foundation
import Testing
import UIKit
@testable import clawchat

@MainActor
struct ChatAudioPlaybackTests {
    @Test func cancelledFailureCannotOverwriteRestartOfSameMessage() async throws {
        let gate = AudioPreparationGate()
        let coordinator = ChatAudioPlaybackCoordinatorV2 { _ in await gate.prepare() }
        defer { coordinator.stop(); gate.finishAll() }
        let block = audio("same-message")
        coordinator.toggle(block: block)
        try await gate.waitForRequests(1)
        coordinator.toggle(block: block) // Cancel loading.
        #expect(coordinator.state == .idle)
        coordinator.toggle(block: block) // Restart the same message.
        try await gate.waitForRequests(2)
        gate.finish(0)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.state.loadingBlockID == block.id)
        #expect(coordinator.state.failedBlockID == nil)
        gate.finish(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.state.failedBlockID == block.id)
    }

    @Test func cancelledSuccessCannotStartPlayerAfterRestart() async throws {
        let gate = AudioPreparationGate()
        let coordinator = ChatAudioPlaybackCoordinatorV2 { _ in await gate.prepare() }
        defer { coordinator.stop(); gate.finishAll() }
        let block = audio("same-message")
        coordinator.toggle(block: block)
        try await gate.waitForRequests(1)
        coordinator.stop()
        coordinator.toggle(block: block)
        try await gate.waitForRequests(2)
        // A stale success must not construct an AVPlayer. This missing file
        // would fail playback and overwrite the new request if accepted.
        gate.finish(0, url: URL(fileURLWithPath: "/missing-stale-voice.wav"))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(coordinator.state.loadingBlockID == block.id)
        #expect(coordinator.state.failedBlockID == nil)
    }

    @Test func stoppedDownloadCannotRestoreAnyPlaybackState() async throws {
        let gate = AudioPreparationGate()
        let coordinator = ChatAudioPlaybackCoordinatorV2 { _ in await gate.prepare() }
        defer { coordinator.stop(); gate.finishAll() }
        coordinator.toggle(block: audio("cancelled"))
        try await gate.waitForRequests(1)
        coordinator.stop()
        gate.finish(0)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.state == .idle)
    }

    @Test func voiceControlsKeepExactGeometryAcrossAllStatesAndReattachment() {
        for outgoing in [false, true] {
            for duration in ["6\"", "90\""] {
                let button = ChatAudioMessageButtonV2(frame: CGRect(x: 0, y: 0, width: 118, height: 60), isOutgoing: outgoing, duration: duration)
                button.layoutIfNeeded()
                let iconFrame = button.playbackIcon.frame
                let textFrame = button.durationLabel.frame
                #expect(iconFrame.midY == button.bounds.midY)
                #expect(textFrame.midY == button.bounds.midY)
                #expect(button.bounds.contains(iconFrame))
                #expect(button.bounds.contains(textFrame))
                for (playing, loading, failed) in [(true, false, false), (false, true, false), (false, false, true), (false, false, false)] {
                    button.update(isPlaying: playing, isLoading: loading, didFail: failed)
                    button.layoutIfNeeded()
                    #expect(button.playbackIcon.frame == iconFrame)
                    #expect(button.loadingIndicator.frame == iconFrame)
                    #expect(button.durationLabel.frame == textFrame)
                }
                let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
                host.addSubview(button)
                host.layoutIfNeeded()
                button.removeFromSuperview()
                host.addSubview(button)
                host.layoutIfNeeded()
                #expect(button.playbackIcon.frame == iconFrame)
                #expect(button.durationLabel.frame == textFrame)
            }
        }
    }

    private func audio(_ id: String) -> AudioBlockContentV2 {
        AudioBlockContentV2(id: id, urlString: "https://example.test/voice.wav", durationSeconds: 6, durationLabel: "6\"")
    }
}

@MainActor
private final class AudioPreparationGate {
    private var requests: [CheckedContinuation<URL?, Never>?] = []

    func prepare() async -> URL? {
        await withCheckedContinuation { requests.append($0) }
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<100 {
            if requests.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(requests.count >= count, "Audio preparation must actually start")
    }

    func finish(_ index: Int, url: URL? = nil) {
        guard requests.indices.contains(index) else { return }
        requests[index]?.resume(returning: url)
        requests[index] = nil
    }

    func finishAll() {
        for index in requests.indices { finish(index) }
    }
}
