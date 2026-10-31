import Darwin
import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

/// Opt-in ONLY: offline existing bundle, private process, real production lifecycle.
/// CI never enables this; no install/download, store receipt, microphone or daemon.
struct ParakeetReloadHardwareProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOX_RELOAD_PROBE"] == "1"))
    func existingModelFreshReuseUnloadReload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VOX_RELOAD_MODEL_DIRECTORY"], let result = env["VOX_RELOAD_RESULT"] else {
            throw ReloadProbeError.missingArguments
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let recorder = ReloadRecorder(URL(fileURLWithPath: result))
        recorder.record("probe-start", extra: ["modelId": "parakeet:v3", "revision": ParakeetModelManifest.v3.revision])
        do {
            for name in ParakeetModelManifest.v3.requiredModelFiles.union([ParakeetModelManifest.v3.vocabularyFile]) {
                guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                    throw ReloadProbeError.missingArtifacts
                }
            }
            let runtime = ParakeetCoreMLRuntime(manifest: .v3)
            // This private short-lived sequence explicitly unloads after each residency.
            try await runtime.setIdleUnload(seconds: 0)
            for phase in ["fresh", "reuse", "reload"] {
                if phase != "reuse" {
                    let free = recorder.freeDiskBytes()
                    guard free >= 5 * 1024 * 1024 * 1024 else {
                        recorder.record("blocked-headroom", extra: ["nextPhase": phase])
                        throw ReloadProbeError.insufficientDisk
                    }
                }
                recorder.record(phase + "-load-start")
                let started = ContinuousClock.now
                try await runtime.load(from: directory) { event in
                    recorder.record(phase + "-progress-" + event.status)
                }
                let loadMs = ms(started.duration(to: .now))
                let ready = await runtime.snapshot()
                guard ready.preloaded, ready.placement?.verified == true else { throw ReloadProbeError.placement }
                recorder.record(phase + "-ready", extra: ["elapsedMs": loadMs, "placement": ready.placement!.dictionaryValue()])
                let inference = ContinuousClock.now
                // Generated silence, 19 s: exercises native long-form path, no user audio.
                let decoded = try await runtime.transcribe(samples: [Float](repeating: 0, count: 19 * 16000))
                recorder.record(phase + "-after-dictation", extra: ["elapsedMs": ms(inference.duration(to: .now)),
                    "audioMs": 19000, "textLength": decoded.text.count])
                if phase != "fresh" {
                    try await runtime.unload()
                    let unloaded = await runtime.snapshot()
                    guard !unloaded.preloaded, unloaded.placement == nil else { throw ReloadProbeError.unload }
                    try await Task.sleep(for: .milliseconds(300))
                    recorder.record(phase + "-after-unload")
                }
            }
            recorder.record("completed")
        } catch {
            recorder.record("failed", extra: ["errorType": String(reflecting: type(of: error))])
            throw error
        }
    }
}

private enum ReloadProbeError: Error { case missingArguments, missingArtifacts, insufficientDisk, placement, unload }
private func ms(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
}
private final class ReloadRecorder: @unchecked Sendable {
    private let output: URL
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    init(_ output: URL) { self.output = output }
    func freeDiskBytes() -> Int64 {
        var fs = statfs()
        guard statfs(FileManager.default.temporaryDirectory.path, &fs) == 0 else { return -1 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
    func record(_ phase: String, extra: [String: Any] = [:]) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var pressure: Int32 = -1
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var entry = extra
        entry["phase"] = phase
        entry["utc"] = ISO8601DateFormatter().string(from: Date())
        entry["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        entry["freeDiskBytes"] = freeDiskBytes()
        entry["memoryPressureLevel"] = pressure
        entry["swapUsedBytes"] = swap.xsu_used
        entry["footprintBytes"] = status == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
        entry["lifetimePeakFootprintBytes"] = status == KERN_SUCCESS ? info.ledger_phys_footprint_peak : -1
        lock.withLock {
            records.append(entry)
            let document: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "records": records]
            do {
                let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } catch {
                FileHandle.standardError.write(Data("Reload probe metrics write failed\n".utf8))
            }
        }
        print("RELOAD_PROBE phase=\(phase) footprintBytes=\(entry["footprintBytes"]!) freeDiskBytes=\(entry["freeDiskBytes"]!)")
        fflush(stdout)
    }
}
