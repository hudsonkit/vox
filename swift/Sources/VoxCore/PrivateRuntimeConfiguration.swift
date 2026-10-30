import Foundation
import Security

/// Official private-daemon bootstrap. Generated credentials live in memory and the
/// owner-only runtime capability, never launchd arguments, a plist, or process env.
public struct PrivateRuntimeConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let socketPath: String
    public let authToken: String
    public let generatedToken: Bool
    public var description: String { "PrivateRuntimeConfiguration(socketPath: \(socketPath), authToken: <redacted>)" }
    public var debugDescription: String { description }

    /// Legacy TCP remains unchanged unless --private or VOX_SOCKET_PATH selects private mode.
    public static func resolve(arguments: [String], environment: [String: String]) throws -> Self? {
        guard arguments.contains("--private") || environment["VOX_SOCKET_PATH"] != nil else { return nil }
        guard !arguments.contains("--port") else { throw PrivateRuntimeConfigurationError.conflictingTCPPort }
        let path = environment["VOX_SOCKET_PATH"] ?? RuntimePaths.voxHomeURL(environment: environment)
            .appendingPathComponent("voxd.sock").path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              path.utf8.count < 104 else { throw PrivateRuntimeConfigurationError.invalidSocketPath }
        let token: String
        let generated: Bool
        if let supplied = environment["VOX_AUTH_TOKEN"] {
            guard !supplied.isEmpty, supplied.utf8.count <= 4096,
                  supplied.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw PrivateRuntimeConfigurationError.invalidAuthToken }
            token = supplied; generated = false
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw PrivateRuntimeConfigurationError.randomnessUnavailable
            }
            token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            generated = true
        }
        return Self(socketPath: path, authToken: token, generatedToken: generated)
    }
}

public enum PrivateRuntimeConfigurationError: Error, LocalizedError, Sendable {
    case conflictingTCPPort, invalidSocketPath, invalidAuthToken, randomnessUnavailable
    public var errorDescription: String? {
        switch self {
        case .conflictingTCPPort: return "Private Vox mode cannot be combined with --port"
        case .invalidSocketPath: return "Private Vox requires an absolute Unix socket path shorter than 104 UTF-8 bytes"
        case .invalidAuthToken: return "Invalid explicit private Vox auth token"
        case .randomnessUnavailable: return "Unable to generate a secure private Vox credential"
        }
    }
}
