import AVFoundation
import Darwin
import Foundation
import HudsonSpeechEngine
import VoxCore

/// Hardware diagnostic through public production providers, never an injected runtime.
/// Installation must already exist; readiness/priming and actual unload are measured.
enum NativeLifecycleBenchmark {
    static func run(arguments: [String]) async throws {
        guard arguments.count >= 5, let index = arguments.firstIndex(of: "--report"),
              arguments.indices.contains(index + 1) else {
            throw StreamingASRError.unavailable("Usage: vox-asr-bench lifecycle MODEL_ID AUDIO_16K_MONO_WAV --report PRIVATE_JSON [--idle-seconds 2]")
        }
        let modelId = arguments[2]
        let input = URL(fileURLWithPath: arguments[3])
        let report = URL(fileURLWithPath: arguments[index + 1])
        let recorder = LifecycleRecorder(output: report)
        let batch = ParakeetProvider()
        let live = NativeStreamingASR.shared
        let isBatch = modelId == "parakeet:v3"
        guard isBatch || modelId == StreamingASRDefaults.modelId else {
            throw StreamingASRError.unavailable("Lifecycle probe supports Parakeet v3 or the default Unified model")
        }
        let provider: any ASRProvider = isBatch ? batch : live
        let file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw StreamingASRError.unavailable("Expected mono 16 kHz WAV")
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let inventory = await provider.models()
        guard inventory.contains(where: { $0.id == modelId && $0.installed && $0.available }) else {
            throw StreamingASRError.unavailable("Existing supported installed model required; no install is attempted")
        }
        let idleIndex = arguments.firstIndex(of: "--idle-seconds")
        let idle = idleIndex.flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 2
        guard idle.isFinite, idle > 0, idle <= 60 else { throw StreamingASRError.unavailable("Invalid probe idle timeout") }
        func setIdle(_ seconds: Double) async throws {
            if isBatch { try await batch.setIdleUnload(modelId: modelId, seconds: seconds) }
            else { try await live.setIdleUnload(seconds: seconds) }
        }
        func unload() async throws {
            if isBatch { _ = try await batch.unload(modelId: modelId) }
            else { try await live.unload() }
        }
        try await setIdle(0)
        recorder.record("baseline", fields: ["modelId": modelId, "audioMs": Double(samples.count) / 16])
        do {
            for phase in ["fresh", "reuse", "explicit-reload", "idle-reload"] {
                guard recorder.freeDiskBytes() >= 5 * 1024 * 1024 * 1024 else {
                    recorder.record("blocked-headroom", fields: ["nextPhase": phase])
                    throw StreamingASRError.unavailable("Probe requires its 5 GiB experiment reserve before load")
                }
                recorder.record(phase + "-load-start")
                let start = Date()
                let ready = try await provider.preload(modelId: modelId) { update in
                    recorder.record(phase + "-progress-" + update.status)
                }
                guard ready.preloaded, ready.computePlacement?.verified == true else {
                    throw StreamingASRError.unavailable("No verified ANE placement")
                }
                recorder.record(phase + "-ready", fields: ["elapsedMs": Date().timeIntervalSince(start) * 1000,
                    "placement": ready.computePlacement!.dictionaryValue()])
                let inference = Date()
                var text: String
                if isBatch {
                    text = try await batch.transcribe(url: input, modelId: modelId).text
                } else {
                    let id = try await live.begin(clientId: "vox-lifecycle-bench", modelId: modelId)
                    do {
                        for offset in stride(from: 0, to: samples.count, by: 1280) {
                            _ = try await live.append(sessionId: id, clientId: "vox-lifecycle-bench",
                                samples: Array(samples[offset..<min(offset + 1280, samples.count)]))
                        }
                        text = try await live.finish(sessionId: id, clientId: "vox-lifecycle-bench").text
                    } catch {
                        try? await live.cancel(sessionId: id, clientId: "vox-lifecycle-bench")
                        throw error
                    }
                }
                recorder.record(phase + "-inference-completed", fields: ["elapsedMs": Date().timeIntervalSince(inference) * 1000,
                    "textLength": text.count, "text": text])
                if phase == "reuse" || phase == "idle-reload" {
                    try await unload()
                    let after = await provider.models().first { $0.id == modelId }
                    guard after?.preloaded == false, after?.computePlacement == nil else {
                        throw StreamingASRError.unavailable("Explicit unload did not clear actual readiness/placement")
                    }
                    try await Task.sleep(for: .seconds(1))
                    recorder.record(phase + "-unloaded")
                } else if phase == "explicit-reload" {
                    try await setIdle(idle)
                    let deadline = Date().addingTimeInterval(idle + 10)
                    while await provider.models().first(where: { $0.id == modelId })?.preloaded == true {
                        guard Date() < deadline else { throw StreamingASRError.unavailable("Idle unload did not occur") }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    recorder.record("idle-unloaded", fields: ["configuredIdleSeconds": idle])
                    try await setIdle(0)
                }
            }
            recorder.record("completed")
        } catch {
            recorder.record("failed", fields: ["errorType": String(reflecting: type(of: error))])
            throw error
        }
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    private let output: URL
    private let lock = NSLock()
    private var records: [[String: Any]] = []
    init(output: URL) { self.output = output }
    func freeDiskBytes() -> Int64 {
        var fs = statfs()
        guard statfs(FileManager.default.temporaryDirectory.path, &fs) == 0 else { return -1 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
    func record(_ phase: String, fields: [String: Any] = [:]) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var pressure: Int32 = -1; var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        var entry = fields
        entry.merge(["phase": phase, "utc": ISO8601DateFormatter().string(from: Date()),
                     "uptimeSeconds": ProcessInfo.processInfo.systemUptime, "freeDiskBytes": freeDiskBytes(),
                     "memoryPressureLevel": pressure, "footprintBytes": status == KERN_SUCCESS ? Int64(info.phys_footprint) : -1,
                     "lifetimePeakFootprintBytes": status == KERN_SUCCESS ? info.ledger_phys_footprint_peak : -1]) { _, new in new }
        lock.withLock {
            records.append(entry)
            do {
                let data = try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "records": records], options: [.sortedKeys, .prettyPrinted])
                try data.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } catch { FileHandle.standardError.write(Data("Lifecycle metrics write failed\n".utf8)) }
        }
        print("LIFECYCLE phase=\(phase) footprintBytes=\(entry["footprintBytes"]!) freeDiskBytes=\(entry["freeDiskBytes"]!)")
        fflush(stdout)
    }
}
