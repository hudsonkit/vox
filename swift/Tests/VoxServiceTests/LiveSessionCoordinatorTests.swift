import Foundation
import Testing
@testable import VoxService

struct LiveSessionCoordinatorTests {
    @Test("Only one live session can be active at a time")
    func beginRejectsSecondSession() throws {
        let coordinator = LiveSessionCoordinator()

        _ = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )

        #expect(throws: Error.self) {
            _ = try coordinator.begin(
                connectionID: "b",
                clientId: "client-b",
                modelId: "parakeet:v3",
                progress: { _, _ in },
                reply: { _, _ in }
            )
        }
    }

    @Test("Busy error gives same caller a cancel-and-retry path")
    func busyErrorExplainsSameCallerRecovery() throws {
        let coordinator = LiveSessionCoordinator()

        _ = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )

        do {
            _ = try coordinator.begin(
                connectionID: "b",
                clientId: "client-a",
                modelId: "parakeet:v3",
                progress: { _, _ in },
                reply: { _, _ in }
            )
            Issue.record("Expected busy error")
        } catch {
            #expect(error.localizedDescription.contains("live_session_busy"))
            #expect(error.localizedDescription.contains("client client-a already owns session"))
            #expect(error.localizedDescription.contains("cancel the active session and retry"))
        }
    }

    @Test("Active session can be finished by connection")
    func finishByConnectionRemovesSession() throws {
        let coordinator = LiveSessionCoordinator()
        let session = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )

        let finished = coordinator.finish(connectionID: "a")
        #expect(finished?.sessionId == session.sessionId)
        #expect(coordinator.current(id: nil) == nil)
    }

    @Test("Status exposes the active session owner and state")
    func statusReflectsActiveSession() throws {
        let coordinator = LiveSessionCoordinator()
        let session = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )

        let status = coordinator.status()
        #expect(status?.sessionId == session.sessionId)
        #expect(status?.clientId == "client-a")
        #expect(status?.modelId == "parakeet:v3")
        #expect(status?.state == .starting)
        #expect(status?.connectionID == "a")
    }

    @Test("Starting timeout releases a session stuck before recording")
    func startingTimeoutReleasesSession() async throws {
        let coordinator = LiveSessionCoordinator()
        let probe = TimeoutProbe()

        coordinator.onStartingTimeout = { session in
            probe.record(session.sessionId)
        }

        let session = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )

        coordinator.startStartingTimer(timeout: 0.01)
        // The timer runs at utility QoS, so a busy parallel test run can delay
        // it well past the timeout. Wait for it to fire instead of guessing.
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.value() == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(coordinator.current(id: nil) == nil)
        #expect(probe.value() == session.sessionId)
    }

    @Test("Recording timeout does not cancel a session already processing")
    func recordingTimeoutIgnoresProcessingSession() async throws {
        let coordinator = LiveSessionCoordinator()
        let probe = TimeoutProbe()

        coordinator.onRecordingTimeout = { session in
            probe.record(session.sessionId)
        }

        let session = try coordinator.begin(
            connectionID: "a",
            clientId: "client-a",
            modelId: "parakeet:v3",
            progress: { _, _ in },
            reply: { _, _ in }
        )
        session.state = .recording

        coordinator.startRecordingTimer(timeout: 0.01)
        let processing = coordinator.markProcessing(id: session.sessionId)
        try await Task.sleep(for: .milliseconds(60))

        #expect(processing?.sessionId == session.sessionId)
        #expect(coordinator.current(id: nil)?.sessionId == session.sessionId)
        #expect(coordinator.current(id: nil)?.state == .processing)
        #expect(probe.value() == nil)
    }
}

private final class TimeoutProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionId: String?

    func record(_ sessionId: String) {
        lock.lock()
        self.sessionId = sessionId
        lock.unlock()
    }

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessionId
    }
}
