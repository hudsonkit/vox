// Component isolation only, not ASR/normal-Agent acceptance. Existing compiled
// encoder, public Core ML APIs, no inference/download/cache deletion/retry.
// Requires ANE planned heavy compute, actual weak-reference teardown and a
// private new report path. No model, plan or asset is retained across unload.
@preconcurrency import CoreML
import Foundation
import Darwin
import CryptoKit

@MainActor final class WeakObjects {
    weak var model: MLModel?
    weak var plan: MLComputePlan?
    weak var asset: MLModelAsset?
}

@available(macOS 15, *)
@MainActor final class Probe {
    let url: URL
    let output: URL
    let mode: String
    let idle: Double
    let weakObjects = WeakObjects()
    var records: [[String: Any]] = []
    var model: MLModel?
    var asset: MLModelAsset?
    init(url: URL, output: URL, mode: String, idle: Double) {
        self.url = url; self.output = output; self.mode = mode; self.idle = idle
    }
    func resources() -> [String: Any] {
        var fs = statfs(); _ = statfs(NSTemporaryDirectory(), &fs)
        var pressure: Int32 = -1; var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ["utc": ISO8601DateFormatter().string(from: Date()),
                "freeDiskBytes": UInt64(fs.f_bavail) * UInt64(fs.f_bsize),
                "pressure": pressure, "footprintBytes": result == KERN_SUCCESS ? info.phys_footprint : 0,
                "lifetimePeakFootprintBytes": result == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0]
    }
    func record(_ phase: String, _ fields: [String: Any] = [:]) throws {
        var row = resources(); row["phase"] = phase; row.merge(fields) { _, newer in newer }
        records.append(row)
        let value: [String: Any] = ["pid": getpid(), "mode": mode, "idleSeconds": idle,
                                   "modelURLSHA256": SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined(),
                                   "records": records]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        print("PHASE \(phase)"); fflush(stdout)
    }
    func admission(launch: Bool = false) throws {
        let snapshot = resources()
        guard (snapshot["freeDiskBytes"] as? UInt64 ?? 0) >= 5 * 1024 * 1024 * 1024,
              [Int32(1), Int32(2)].contains(snapshot["pressure"] as? Int32 ?? -1),
              !launch || (snapshot["pressure"] as? Int32) == 1 else {
            throw NSError(domain: "CoreMLCacheProbePolicy", code: 1)
        }
    }
    func measure<T>(_ phase: String, _ body: () async throws -> T) async throws -> T {
        try admission()
        try record(phase + "-start")
        let start = ContinuousClock.now
        do {
            let value = try await body()
            let d = start.duration(to: .now).components
            try record(phase + "-completed", ["elapsedMs": Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15])
            return value
        } catch {
            var causes: [[String: Any]] = []; var current: NSError? = error as NSError
            for _ in 0..<3 {
                guard let e = current else { break }
                let safe = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "com.apple.CoreML", "CoreMLCacheProbePolicy"]
                causes.append(["domain": safe.contains(e.domain) ? e.domain : "other", "code": e.code])
                current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            try? record(phase + "-failed", ["causes": causes]); throw error
        }
    }
    func readPlan(configuration: MLModelConfiguration) async throws -> [String: Int] {
        let plan: MLComputePlan
        if let asset { plan = try await MLComputePlan.load(asset: asset, configuration: configuration) }
        else { plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration) }
        weakObjects.plan = plan
        var counts = ["ane": 0, "cpu": 0, "gpu": 0, "unknown": 0, "aneCompute": 0, "cpuCompute": 0]
        func walk(_ block: MLModelStructure.Program.Block) {
            for op in block.operations {
                let name = op.operatorName.split(separator: ".").last.map(String.init) ?? op.operatorName
                if name != "const" {
                    let compute = ["conv", "linear", "matmul"].contains(name)
                    if let usage = plan.deviceUsage(for: op) {
                        switch usage.preferred {
                        case .neuralEngine: counts["ane", default: 0] += 1; if compute { counts["aneCompute", default: 0] += 1 }
                        case .cpu: counts["cpu", default: 0] += 1; if compute { counts["cpuCompute", default: 0] += 1 }
                        case .gpu: counts["gpu", default: 0] += 1
                        @unknown default: counts["unknown", default: 0] += 1
                        }
                    } else { counts["unknown", default: 0] += 1 }
                }
                for nested in op.blocks { walk(nested) }
            }
        }
        guard case .program(let program) = plan.modelStructure else { throw NSError(domain: "CoreMLCacheProbePolicy", code: 2) }
        for function in program.functions.values { walk(function.block) }
        guard counts["aneCompute", default: 0] > 0, counts["cpuCompute", default: 0] == 0, counts["gpu", default: 0] == 0 else {
            throw NSError(domain: "CoreMLCacheProbePolicy", code: 3)
        }
        return counts
    }
    func phase(_ name: String, reuse: Bool = false) async throws {
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
        if mode != "plan-only", !reuse {
            if mode == "shared-asset", asset == nil {
                try admission()
                asset = try MLModelAsset(url: url)
                weakObjects.asset = asset
                try record(name + "-asset-opened")
            }
            model = try await measure(name + "-model-load") {
                if let asset { return try await MLModel.load(asset: asset, configuration: configuration) }
                return try await MLModel.load(contentsOf: url, configuration: configuration)
            }
            weakObjects.model = model
        }
        let placement = try await measure(name + "-plan") { try await readPlan(configuration: configuration) }
        try record(name + "-verified", ["placement": placement])
        // Give Objective-C completion/autorelease lifetimes time to leave their queues.
        try await Task.sleep(for: .milliseconds(500))
        try record(name + "-plan-lifetime", ["planStillAlive": weakObjects.plan != nil])
        guard weakObjects.plan == nil else { throw NSError(domain: "CoreMLCacheProbePolicy", code: 4) }
    }
    func unload(_ name: String) async throws {
        model = nil
        asset = nil
        try await Task.sleep(for: .seconds(1))
        try record(name + "-unloaded", ["modelStillAlive": weakObjects.model != nil, "planStillAlive": weakObjects.plan != nil, "assetStillAlive": weakObjects.asset != nil])
        guard weakObjects.model == nil, weakObjects.plan == nil, weakObjects.asset == nil else { throw NSError(domain: "CoreMLCacheProbePolicy", code: 5) }
    }
    func run() async throws {
        try record("baseline")
        try admission(launch: true)
        guard MLModel.availableComputeDevices.contains(where: {
            if case .neuralEngine = $0 { return true }; return false
        }) else { throw NSError(domain: "CoreMLCacheProbePolicy", code: 6) }
        for path in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
            let a = try FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(path).path)
            try record("artifact", ["relativePath": path, "size": a[.size]!, "inode": a[.systemFileNumber]!,
                                    "modifiedUnixSeconds": (a[.modificationDate] as! Date).timeIntervalSince1970])
        }
        try await phase("fresh")
        try await phase("resident-plan-reuse", reuse: true)
        try await unload("explicit")
        try await phase("explicit-reload")
        try await unload("before-idle")
        try record("idle-wait")
        try await Task.sleep(for: .seconds(idle))
        try await phase("idle-reload")
        try await unload("final")
        try record("completed")
    }
}

@main struct Main {
    @MainActor static func main() async {
        umask(0o077)
        let a = CommandLine.arguments
        if a.count == 2, a[1] == "--describe" {
            print("CoreML-only existing-encoder isolation; model-plan/plan-only/shared-asset; no inference/install/CPU fallback; 5GiB before each API; launch pressure1, then reject critical pressure; weak-reference teardown checks; no automatic retry.")
            return
        }
        guard a.count == 5, ["model-plan", "plan-only", "shared-asset"].contains(a[1]),
              let idle = Double(a[4]), idle > 0, idle <= 60,
              !FileManager.default.fileExists(atPath: a[3]) else {
            fputs("Usage: CoreMLCacheProbe model-plan|plan-only|shared-asset EXISTING_ENCODER.mlmodelc NEW_PRIVATE_REPORT.json IDLE_SECONDS\n", stderr); exit(64)
        }
        if #available(macOS 15, *) {
            let probe = Probe(url: URL(fileURLWithPath: a[2], isDirectory: true), output: URL(fileURLWithPath: a[3]), mode: a[1], idle: idle)
            do { try await probe.run() }
            catch {
                let e = error as NSError
                let safe = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "com.apple.CoreML", "CoreMLCacheProbePolicy"]
                try? probe.record("failed", ["errorDomain": safe.contains(e.domain) ? e.domain : "other", "errorCode": e.code])
                exit(1)
            }
        } else { exit(69) }
    }
}
