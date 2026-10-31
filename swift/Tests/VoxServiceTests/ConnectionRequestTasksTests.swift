import Foundation
import Testing
@testable import VoxService

struct ConnectionRequestTasksTests {
    @Test func disconnectBeforeAttachAndCompleteBeforeAttachAreSafe() async throws {
        let tasks = ConnectionRequestTasks()
        let (_, cancelled) = tasks.reserve(connectionID: "a")
        tasks.cancel(connectionID: "a")
        let late = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        cancelled.attach(late)
        #expect(late.isCancelled)
        let (id, completed) = tasks.reserve(connectionID: "b")
        tasks.finish(connectionID: "b", id: id, ticket: completed)
        let finished = Task<Void, Never> {}
        completed.attach(finished)
        #expect(finished.isCancelled)
    }
    @Test func disconnectDoesNotCancelAnotherConnection() {
        let tasks = ConnectionRequestTasks()
        let (_, a) = tasks.reserve(connectionID: "a")
        let (_, b) = tasks.reserve(connectionID: "b")
        let ta = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        let tb = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        a.attach(ta); b.attach(tb)
        tasks.cancel(connectionID: "a")
        #expect(ta.isCancelled && !tb.isCancelled)
        tasks.cancelAll()
        #expect(tb.isCancelled)
    }
}
