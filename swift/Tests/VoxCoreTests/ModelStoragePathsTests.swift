import Foundation
import Testing
import VoxCore

struct ModelStoragePathsTests {
    @Test func modelsCanBeSharedWithoutSharingRuntimeState() {
        let environment = ["VOX_HOME": "/private/tmp/dev-home", "VOX_MODELS_PATH": "/private/tmp/shared-models", "VOX_RUNTIME_PATH": "/private/tmp/dev-runtime.json"]
        #expect(RuntimePaths.voxHomeURL(environment: environment).path == "/private/tmp/dev-home")
        #expect(RuntimePaths.modelsDirectoryURL(environment: environment).path == "/private/tmp/shared-models")
        #expect(RuntimePaths.modelsDirectoryURL(environment: ["VOX_HOME": "/private/tmp/dev-home"]).path == "/private/tmp/dev-home/cache/models")
        #expect(RuntimePaths.modelsDirectoryOverrideURL(environment: ["VOX_MODELS_PATH": ""]) == nil)
    }
}
