import Foundation

/// Reserve before launching a task. A disconnect between reservation and attachment
/// cancels the later attachment; completion before attachment cannot retain a task.
final class ConnectionRequestTasks: @unchecked Sendable {
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        private var task: Task<Void, Never>?
        func attach(_ task: Task<Void, Never>) {
            let cancel = lock.withLock { () -> Bool in
                guard !ended else { return true }; self.task = task; return false
            }
            if cancel { task.cancel() }
        }
        func end(cancel: Bool) {
            let task = lock.withLock { () -> Task<Void, Never>? in
                ended = true; defer { self.task = nil }; return self.task
            }
            if cancel { task?.cancel() }
        }
    }
    private let lock = NSLock()
    private var tickets: [String: [UUID: Ticket]] = [:]
    func reserve(connectionID: String) -> (UUID, Ticket) {
        lock.withLock {
            let id = UUID(), ticket = Ticket()
            tickets[connectionID, default: [:]][id] = ticket
            return (id, ticket)
        }
    }
    func finish(connectionID: String, id: UUID, ticket: Ticket) {
        ticket.end(cancel: false)
        lock.withLock {
            tickets[connectionID]?[id] = nil
            if tickets[connectionID]?.isEmpty == true { tickets[connectionID] = nil }
        }
    }
    func cancel(connectionID: String) {
        let removed = lock.withLock { tickets.removeValue(forKey: connectionID) ?? [:] }
        for ticket in removed.values { ticket.end(cancel: true) }
    }
    func cancelAll() {
        let removed = lock.withLock { let all = tickets; tickets = [:]; return all }
        for group in removed.values { for ticket in group.values { ticket.end(cancel: true) } }
    }
}
