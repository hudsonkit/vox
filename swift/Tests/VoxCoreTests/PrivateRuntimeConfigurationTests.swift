import Foundation
import Testing
@testable import VoxCore

struct PrivateRuntimeConfigurationTests {
    @Test func explicitPrivateModeGeneratesFreshCredentialsWithoutEnvironmentSecrets() throws {
        let env = ["VOX_HOME": "/private/tmp/vox-bootstrap-test"]
        let first = try #require(try PrivateRuntimeConfiguration.resolve(arguments: ["voxd", "--private"], environment: env))
        let second = try #require(try PrivateRuntimeConfiguration.resolve(arguments: ["voxd", "--private"], environment: env))
        #expect(first.socketPath == "/private/tmp/vox-bootstrap-test/voxd.sock")
        #expect(first.generatedToken)
        #expect(first.authToken.utf8.count == 43)
        #expect(first.authToken != second.authToken)
        #expect(!String(describing: first).contains(first.authToken))
        #expect(!String(reflecting: first).contains(first.authToken))
        #expect(env["VOX_AUTH_TOKEN"] == nil)
    }
    @Test func privateSocketOverrideCanGenerateOrUseAnExplicitToken() throws {
        let generated = try #require(try PrivateRuntimeConfiguration.resolve(arguments: [],
            environment: ["VOX_SOCKET_PATH": "/private/tmp/test/vox.sock"]))
        #expect(generated.generatedToken)
        let explicit = try #require(try PrivateRuntimeConfiguration.resolve(arguments: [],
            environment: ["VOX_SOCKET_PATH": "/private/tmp/test/vox.sock", "VOX_AUTH_TOKEN": "host-provided-test-token"]))
        #expect(!explicit.generatedToken)
        #expect(explicit.authToken == "host-provided-test-token")
    }
    @Test func invalidExplicitConfigurationFailsInsteadOfChangingTransportOrCredentials() {
        for env in [["VOX_SOCKET_PATH": ""], ["VOX_SOCKET_PATH": "relative.sock"],
                    ["VOX_SOCKET_PATH": "/private/tmp/../bad.sock"], ["VOX_SOCKET_PATH": "/private//tmp/bad.sock"],
                    ["VOX_AUTH_TOKEN": ""], ["VOX_AUTH_TOKEN": "bad\r\nheader"],
                    ["VOX_SOCKET_PATH": "/" + String(repeating: "x", count: 104)]] {
            #expect(throws: (any Error).self) {
                try PrivateRuntimeConfiguration.resolve(arguments: ["--private"], environment: env)
            }
        }
        #expect(throws: (any Error).self) {
            try PrivateRuntimeConfiguration.resolve(arguments: ["--private", "--port", "1234"], environment: [:])
        }
    }
    @Test func legacyTCPDoesNotGenerateACredentialImplicitly() throws {
        #expect(try PrivateRuntimeConfiguration.resolve(arguments: ["--port", "1234"], environment: [:]) == nil)
        #expect(try PrivateRuntimeConfiguration.resolve(arguments: [], environment: ["VOX_AUTH_TOKEN": "tcp-test-token"]) == nil)
    }
}
