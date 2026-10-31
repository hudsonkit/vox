import Darwin
import Foundation

/// A credential-bearing local file, never a health/status response. Do not log its JSON.
/// Metadata remains decodable as RuntimeInfo without exposing the credential on that type.
public struct PrivateRuntimeCapability: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let schemaVersion: Int
    public let instanceId: UUID
    public let runtime: RuntimeInfo
    public let authToken: String
    public static let transport = "unix+ws+json-rpc"
    public var description: String { "PrivateRuntimeCapability(instanceId: \(instanceId), authToken: <redacted>)" }
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey { case schemaVersion, instanceId, transport, authToken }
    public init(runtime: RuntimeInfo, authToken: String, instanceId: UUID = UUID()) throws {
        guard let path = runtime.socketPath, path.hasPrefix("/"), !path.utf8.contains(0), runtime.port == 0,
              !authToken.isEmpty, authToken.utf8.count <= 4096,
              authToken.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw POSIXError(.EINVAL) }
        self.schemaVersion = 1; self.instanceId = instanceId; self.runtime = runtime; self.authToken = authToken
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1,
              try c.decode(String.self, forKey: .transport) == Self.transport else { throw POSIXError(.EINVAL) }
        try self.init(runtime: RuntimeInfo(from: decoder), authToken: c.decode(String.self, forKey: .authToken),
                      instanceId: c.decode(UUID.self, forKey: .instanceId))
    }
    public func encode(to encoder: any Encoder) throws {
        try runtime.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(instanceId, forKey: .instanceId)
        try c.encode(Self.transport, forKey: .transport); try c.encode(authToken, forKey: .authToken)
    }
    /// Missing is nil; malformed, unsafe or unreadable capabilities throw, never trigger TCP fallback.
    public static func read(from url: URL = RuntimePaths.runtimeFileURL()) throws -> PrivateRuntimeCapability? {
        do { return try JSONDecoder().decode(Self.self, from: VoxPrivateFiles.read(url)) }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
}

/// One publisher per private runtime path. The lease prevents another private daemon
/// from replacing this capability; isolated hosts must select different VOX_RUNTIME_PATHs.
public final class PrivateRuntimeRegistration: @unchecked Sendable {
    private let capability: PrivateRuntimeCapability
    private let url: URL
    private let lock = NSLock()
    private var lease: Int32

    public init(runtime: RuntimeInfo, authToken: String, url: URL = RuntimePaths.runtimeFileURL()) throws {
        let capability = try PrivateRuntimeCapability(runtime: runtime, authToken: authToken)
        let lease = try VoxPrivateFiles.lock(url)
        do {
            // Older TCP daemons do not hold our lease. Refuse a live existing owner
            // rather than clobbering its registry and silently creating a second engine.
            do {
                let existing = try VoxPrivateFiles.readRegistryMetadata(url)
                guard existing.pid > 0 else { throw POSIXError(.EACCES) }
                let live = kill(existing.pid, 0)
                guard live != 0, errno == ESRCH else { throw POSIXError(.EADDRINUSE) }
            } catch let error as POSIXError where error.code == .ENOENT {
                // No previous registration.
            }
            try VoxPrivateFiles.write(JSONEncoder().encode(capability), to: url)
        } catch { close(lease); throw error }
        self.capability = capability; self.url = url; self.lease = lease
    }
    public func invalidate() {
        lock.withLock {
            guard lease >= 0 else { return }
            // Never remove metadata/capabilities that no longer describe this instance.
            if let current = try? PrivateRuntimeCapability.read(from: url), current.instanceId == capability.instanceId {
                try? VoxPrivateFiles.remove(url)
            }
            flock(lease, LOCK_UN); close(lease); lease = -1
        }
    }
    deinit { invalidate() }
}
