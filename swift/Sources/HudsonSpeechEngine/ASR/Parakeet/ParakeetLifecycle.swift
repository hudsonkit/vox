import Foundation
import VoxCore

public enum ParakeetLifecycleError: Error, LocalizedError, Sendable {
    case busy, unsafeStore, unsupported, invalidIdleTimeout
    public var errorDescription: String? {
        switch self {
        case .busy: return "parakeet_lifecycle_busy: a model operation or initialization is active"
        case .unsafeStore: return "parakeet_unsafe_store: refusing an unsafe or unowned model directory"
        case .unsupported: return "parakeet_lifecycle_unsupported: runtime does not support this lifecycle operation"
        case .invalidIdleTimeout: return "parakeet_invalid_idle_timeout: expected finite nonnegative seconds"
        }
    }
}

/// Shared by every provider referencing this process-wide engine. Reservations
/// cover the entire operation, including install/audio preparation before inference.
actor ParakeetOperations {
    private var users = Set<UUID>()
    private var exclusive = false
    private var installation: (id: UUID, task: Task<URL, Error>, progress: Observers)?

    func withUse<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !exclusive else { throw ParakeetLifecycleError.busy }
        let id = UUID(); users.insert(id); defer { users.remove(id) }
        return try await operation()
    }
    func withExclusive<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard !exclusive, users.isEmpty, installation == nil else { throw ParakeetLifecycleError.busy }
        exclusive = true; defer { exclusive = false }
        return try await operation()
    }
    func installed(_ store: ParakeetModelStore, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> URL {
        let flight: (id: UUID, task: Task<URL, Error>, progress: Observers)
        if let existing = installation { flight = existing; flight.progress.add(progress) }
        else {
            let observers = Observers()
            observers.add(progress)
            flight = (UUID(), Task { try await store.ensureInstalled { observers.publish($0) } }, observers)
            installation = flight
        }
        do {
            let directory = try await flight.task.value
            if installation?.id == flight.id { installation = nil }
            try Task.checkCancellation()
            return directory
        } catch {
            if installation?.id == flight.id { installation = nil }
            throw error
        }
    }
    private final class Observers: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [@Sendable (ModelProgress) -> Void] = []
        private var last: ModelProgress?
        func add(_ callback: @escaping @Sendable (ModelProgress) -> Void) {
            let value = lock.withLock { callbacks.append(callback); return last }
            if let value { callback(value) }
        }
        func publish(_ value: ModelProgress) {
            let listeners = lock.withLock { last = value; return callbacks }
            for callback in listeners { callback(value) }
        }
    }
}
