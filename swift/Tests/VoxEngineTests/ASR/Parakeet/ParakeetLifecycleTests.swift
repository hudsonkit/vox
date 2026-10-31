import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

@Suite(.timeLimit(.minutes(1)))
struct ParakeetLifecycleTests {
    @Test("Inventory/install do not load Core ML; unload releases the shared session and deletion preserves siblings")
    func publicLifecycleAndSharedReferenceRelease() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let other = ParakeetProvider(sharing: fixture.provider)
        #expect(try fixture.provider.modelDirectory(modelId: "parakeet:v3") == fixture.store.preferredInstallDirectory())
        #expect(await fixture.provider.models().first?.installed == false)
        #expect(await fixture.factory.loads == 0)
        let installed = try await fixture.provider.install(modelId: "parakeet:v3") { _ in }
        #expect(installed.installed && !installed.preloaded)
        #expect(await fixture.factory.loads == 0 && fixture.witness.alive == false)
        #expect(await fixture.downloads.value == 1)
        let prepared = try await fixture.provider.preload(modelId: "parakeet:v3") { _ in }
        #expect(prepared.preloaded && fixture.witness.alive)
        #expect(await other.models().first?.preloaded == true)
        #expect(await fixture.factory.loads == 1)
        let unloaded = try await other.unload(modelId: "parakeet:v3")
        #expect(!unloaded.preloaded && unloaded.installed && unloaded.computePlacement == nil)
        #expect(!fixture.witness.alive, "A shared cached runtime must not retain its loaded Session closure")
        #expect(await fixture.provider.models().first?.preloaded == false)
        _ = try await fixture.provider.preload(modelId: "parakeet:v3") { _ in }
        #expect(await fixture.factory.loads == 2)
        let sibling = fixture.root.appendingPathComponent("models/keep-other-model")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let sentinel = sibling.appendingPathComponent("sentinel")
        try Data([9]).write(to: sentinel)
        let alias = fixture.store.preferredInstallDirectory().appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sibling)
        let deleted = try await other.deleteModel(modelId: "parakeet:v3")
        #expect(!deleted.installed && !deleted.preloaded && !fixture.witness.alive)
        #expect(try Data(contentsOf: sentinel) == Data([9]))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.preferredInstallDirectory().path))
        #expect(await fixture.provider.models().first?.installed == false)
        _ = try await fixture.provider.deleteModel(modelId: "parakeet:v3") // idempotent when absent
    }

    @Test("Unload/delete reject active inference across provider instances")
    func inferenceCannotBeEvicted() async throws {
        let fixture = try Fixture(inference: Pause())
        defer { fixture.remove() }
        let other = ParakeetProvider(sharing: fixture.provider)
        _ = try await fixture.provider.preload(modelId: "parakeet:v3") { _ in }
        let audio = fixture.root.appendingPathComponent("input.wav")
        try PCMWAV.wrap(pcm: Data(repeating: 0, count: 6400), sampleRate: 16000).write(to: audio)
        let operation = Task { try await fixture.provider.transcribe(url: audio, modelId: "parakeet:v3") }
        await fixture.factory.inference!.entered()
        await #expect(throws: ParakeetLifecycleError.self) { try await other.unload(modelId: "parakeet:v3") }
        await #expect(throws: ParakeetLifecycleError.self) { try await other.deleteModel(modelId: "parakeet:v3") }
        #expect(fixture.witness.alive && fixture.store.isInstalled())
        await fixture.factory.inference!.release()
        #expect(try await operation.value.text == "fixture")
        _ = try await other.unload(modelId: "parakeet:v3")
        #expect(!fixture.witness.alive)
    }

    @Test("Installation is single-flight and a cancelled waiter cannot enable deletion during a download")
    func sharedInstallation() async throws {
        let fixture = try Fixture(download: Pause())
        defer { fixture.remove() }
        let other = ParakeetProvider(sharing: fixture.provider)
        let first = Task { try await fixture.provider.install(modelId: "parakeet:v3") { _ in } }
        await fixture.downloads.pause!.entered()
        let second = Task { try await other.install(modelId: "parakeet:v3") { _ in } }
        first.cancel()
        await #expect(throws: ParakeetLifecycleError.self) { try await other.deleteModel(modelId: "parakeet:v3") }
        await fixture.downloads.pause!.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.installed)
        #expect(await fixture.downloads.value == 1)
        #expect(await fixture.factory.loads == 0)
        _ = try await other.deleteModel(modelId: "parakeet:v3")
    }

    @Test("A loading/priming session is not unloaded or reported ready prematurely")
    func warmupCannotBeEvicted() async throws {
        let fixture = try Fixture(loading: Pause())
        defer { fixture.remove() }
        let operation = Task { try await fixture.provider.preload(modelId: "parakeet:v3") { _ in } }
        await fixture.factory.loading!.entered()
        #expect(await fixture.provider.models().first?.preloaded == false)
        await #expect(throws: ParakeetLifecycleError.self) { try await fixture.provider.unload(modelId: "parakeet:v3") }
        await #expect(throws: ParakeetLifecycleError.self) { try await fixture.provider.deleteModel(modelId: "parakeet:v3") }
        await fixture.factory.loading!.release()
        #expect(try await operation.value.preloaded)
        _ = try await fixture.provider.unload(modelId: "parakeet:v3")
        #expect(!fixture.witness.alive)
    }

    @Test("Parakeet idle timeout is configurable without pretending to purge Core ML system caches")
    func idleUnload() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try await fixture.provider.setIdleUnload(modelId: "parakeet:v3", seconds: 0)
        _ = try await fixture.provider.preload(modelId: "parakeet:v3") { _ in }
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.witness.alive)
        await #expect(throws: ParakeetLifecycleError.self) { try await fixture.provider.setIdleUnload(modelId: "parakeet:v3", seconds: .nan) }
        try await fixture.provider.setIdleUnload(modelId: "parakeet:v3", seconds: 0.01)
        for _ in 0..<200 { if !fixture.witness.alive { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(!fixture.witness.alive)
        #expect(await fixture.provider.models().first?.preloaded == false)
    }

    @Test("Idle eviction cannot expire an admitted operation during file preparation")
    func idleReservationSpansPreparation() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        _ = try await fixture.provider.preload(modelId: "parakeet:v3") { _ in }
        await fixture.runtime.beginUse() // same reservation taken by every provider operation
        try await fixture.runtime.setIdleUnload(seconds: 0.01)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.witness.alive)
        await #expect(throws: ParakeetLifecycleError.self) { try await fixture.provider.unload(modelId: "parakeet:v3") }
        await fixture.runtime.endUse()
        for _ in 0..<200 { if !fixture.witness.alive { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(!fixture.witness.alive)
    }

    @Test("Residency unload is model-scoped and never steals a live lease")
    func scopedResidency() async throws {
        let slot = NativeASRResidency(), counter = Downloads()
        let lease = try await slot.acquire(modelId: "parakeet:v3") { await counter.record() }
        try await slot.unload(modelId: "other-model")
        await #expect(throws: StreamingASRError.self) { try await slot.unload(modelId: "parakeet:v3") }
        #expect(await counter.value == 0)
        await slot.release(lease)
        try await slot.unload(modelId: "parakeet:v3")
        #expect(await counter.value == 1)
        try await slot.unload(modelId: "parakeet:v3")
        #expect(await counter.value == 1)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let store: ParakeetModelStore
    let provider: ParakeetProvider
    let factory: Factory
    let runtime: ParakeetCoreMLRuntime
    let witness = Witness()
    let downloads: Downloads
    init(download: Pause? = nil, loading: Pause? = nil, inference: Pause? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        downloads = Downloads(pause: download)
        factory = Factory(witness: witness, loading: loading, inference: inference)
        store = ParakeetModelStore(downloader: Downloader(recorder: downloads), preferredModelsRootDirectory: root.appendingPathComponent("models"))
        let factory = self.factory
        runtime = ParakeetCoreMLRuntime(loadSession: { _ in try await factory.make() }, observeEvent: { _ in })
        provider = ParakeetProvider(store: store, runtime: runtime)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
private final class Marker: @unchecked Sendable {}
private final class Witness: @unchecked Sendable {
    let lock = NSLock()
    private weak var marker: Marker?
    func set(_ value: Marker) { lock.withLock { marker = value } }
    var alive: Bool { lock.withLock { marker != nil } }
}
private actor Pause {
    private var started = false, opened = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async { started = true; if opened { return }; await withCheckedContinuation { waiting = $0 } }
    func entered() async { while !started { await Task.yield() } }
    func release() { opened = true; waiting?.resume(); waiting = nil }
}
private actor Downloads {
    var value = 0
    nonisolated let pause: Pause?
    init(pause: Pause? = nil) { self.pause = pause }
    func record() async { value += 1; await pause?.wait() }
}
private struct Downloader: ParakeetModelArtifactDownloader {
    let recorder: Downloads
    func download(manifest: ParakeetModelManifest, to root: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        await recorder.record()
        let folder = root.appendingPathComponent(manifest.cacheDirectoryName)
        for model in manifest.requiredModelFiles {
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                let path = folder.appendingPathComponent(model).appendingPathComponent(file)
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([1]).write(to: path)
            }
        }
        try Data("{\"0\":\"fixture\"}".utf8).write(to: folder.appendingPathComponent(manifest.vocabularyFile))
    }
}
private actor Factory {
    let witness: Witness
    nonisolated let loading: Pause?, inference: Pause?
    var loads = 0
    init(witness: Witness, loading: Pause?, inference: Pause?) { self.witness = witness; self.loading = loading; self.inference = inference }
    func make() async throws -> ParakeetCoreMLRuntime.Session {
        loads += 1; await loading?.wait()
        let marker = Marker(); witness.set(marker)
        return ParakeetCoreMLRuntime.Session { [marker, self] samples in
            withExtendedLifetime(marker) {}
            if samples.count <= ParakeetConstants.maxModelSamples { await inference?.wait() }
            return ParakeetInferenceResult(text: "fixture", words: [])
        }
    }
}
