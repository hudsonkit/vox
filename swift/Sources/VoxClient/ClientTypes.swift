import Foundation
@_exported import VoxCore

/// Credentials are host-provisioned. No discovery, daemon launch or TCP fallback occurs implicitly.
public enum VoxEndpoint: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case unix(socketPath: String, authToken: String)
    /// Deliberate opt-in only. Unencrypted WebSocket; restrict to a trusted loopback host.
    case tcp(host: String, port: UInt16, authToken: String? = nil)

    public var description: String {
        switch self {
        case .unix(let path, _): return "VoxEndpoint.unix(socketPath: \(path), authToken: <redacted>)"
        case .tcp(let host, let port, _): return "VoxEndpoint.tcp(host: \(host), port: \(port), authToken: <redacted>)"
        }
    }
    public var debugDescription: String { description }

    /// Host capability discovery only. Never launches a daemon or reads TCP metadata as authority.
    /// Explicit environment endpoint pairs take precedence over the owner-only runtime file.
    public static func discovered(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> VoxEndpoint {
        let socket = environment["VOX_SOCKET_PATH"], token = environment["VOX_AUTH_TOKEN"]
        if socket != nil || token != nil {
            guard let socket, !socket.isEmpty, let token, !token.isEmpty else { throw VoxClientError.invalidEndpoint }
            return .unix(socketPath: socket, authToken: token)
        }
        let url: URL
        if let path = environment["VOX_RUNTIME_PATH"], !path.isEmpty { url = URL(fileURLWithPath: path) }
        else if let home = environment["VOX_HOME"], !home.isEmpty { url = URL(fileURLWithPath: home).appendingPathComponent("runtime.json") }
        else { url = RuntimePaths.voxHomeURL(environment: environment).appendingPathComponent("runtime.json") }
        guard let capability = try PrivateRuntimeCapability.read(from: url) else { throw VoxClientError.disconnected }
        return try runtime(capability.runtime, authToken: capability.authToken)
    }

    public static func runtime(_ runtime: RuntimeInfo, authToken: String, allowTCP: Bool = false,
                               tcpHost: String = "127.0.0.1") throws -> VoxEndpoint {
        if let path = runtime.socketPath { return .unix(socketPath: path, authToken: authToken) }
        guard allowTCP, runtime.port != 0 else { throw VoxClientError.tcpNotEnabled }
        return .tcp(host: tcpHost, port: runtime.port, authToken: authToken)
    }
}

public enum VoxClientError: Error, LocalizedError, Sendable, Equatable {
    case disconnected, alreadyConnected, tcpNotEnabled, invalidEndpoint, invalidResponse
    case timeout, backpressure, invalidPCM, streamBusy
    case server(String), protocolViolation(String)
    public var errorDescription: String? {
        switch self {
        case .disconnected: return "Vox daemon disconnected; reconnect and start a new session"
        case .alreadyConnected: return "Vox client already connected or connecting"
        case .tcpNotEnabled: return "TCP requires explicit opt-in; no private transport fallback"
        case .invalidEndpoint: return "Invalid Vox endpoint or credential"
        case .invalidResponse: return "Invalid Vox daemon response"
        case .timeout: return "Vox request timed out; receipt is uncertain, no automatic retry"
        case .backpressure: return "Vox transport queue limit reached"
        case .invalidPCM: return "Expected 1–16000 finite mono 16 kHz float32 samples"
        case .streamBusy: return "Await the current PCM operation before sending another"
        case .server(let detail), .protocolViolation(let detail): return detail
        }
    }
}

public struct VoxRPCProgress: Sendable, Equatable {
    public let event: String
    public let data: JSONValue
}

public struct PCMStreamingSession: Codable, Sendable, Equatable {
    public let sessionId: String
    public let modelId: String
    public let sampleRate: Int
    public let channels: Int
    public let encoding: String
    public let maxPacketSamples: Int
    public let nextSequence: Int
}

public struct PCMStreamingAcknowledgement: Codable, Sendable, Equatable {
    public let sessionId: String
    public let nextSequence: Int
    public let updates: [StreamingASRUpdate]
}
