import Darwin
import Foundation
import VoxCore

/// Admission for stages that can invoke the OS ANE compiler. This is a safety
/// budget, not a claim about a fixed Core ML minimum or specialization cache hit.
enum NativePreparationResources {
    struct Snapshot: Sendable {
        let availableDiskBytes: Int64
        let memoryPressureLevel: Int32
    }
    static var defaultMinimumFreeDiskBytes: Int64 {
        #if os(macOS)
        // A measured compiler allocation grew to 2.40 GiB before ENOSPC.
        // Keep headroom instead of entering an opaque synchronous compiler wait.
        return 3 * 1024 * 1024 * 1024
        #else
        return 0 // Mobile admission needs physical-device measurements first.
        #endif
    }
    static func minimumFreeDiskBytes(environment: [String: String]) throws -> Int64 {
        guard let raw = environment["VOX_ASR_MIN_FREE_DISK_BYTES"] else { return defaultMinimumFreeDiskBytes }
        guard let value = Int64(raw), value >= 0 else { throw NativePreparationError.invalidReserve }
        return value
    }
    static func snapshot() -> Snapshot {
        var fs = statfs()
        let available = statfs(FileManager.default.temporaryDirectory.path, &fs) == 0
            ? Int64(fs.f_bavail) * Int64(fs.f_bsize) : -1
        var pressure: Int32 = -1; var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return Snapshot(availableDiskBytes: available, memoryPressureLevel: pressure)
    }
    static func check(modelId: String, phase: String) throws {
        let state = snapshot()
        let required = try minimumFreeDiskBytes(environment: ProcessInfo.processInfo.environment)
        do { try validate(state, minimumFreeDiskBytes: required) }
        catch {
            VoxLog.engine.warning("Native preparation admission model=\(modelId) phase=\(phase) rejected freeDiskBytes=\(state.availableDiskBytes) requiredDiskBytes=\(required) memoryPressureLevel=\(state.memoryPressureLevel)")
            throw error
        }
        VoxLog.engine.debug("Native preparation admission model=\(modelId) phase=\(phase) accepted freeDiskBytes=\(state.availableDiskBytes) requiredDiskBytes=\(required) memoryPressureLevel=\(state.memoryPressureLevel)")
    }
    static func validate(_ state: Snapshot, minimumFreeDiskBytes: Int64) throws {
        guard state.availableDiskBytes >= 0 else { throw NativePreparationError.resourceQueryFailed }
        guard state.availableDiskBytes >= minimumFreeDiskBytes else {
            throw NativePreparationError.insufficientDisk(available: state.availableDiskBytes, required: minimumFreeDiskBytes)
        }
        guard state.memoryPressureLevel < 4 else { throw NativePreparationError.criticalMemoryPressure }
    }
}

enum NativePreparationError: Error, LocalizedError {
    case invalidReserve, resourceQueryFailed, criticalMemoryPressure
    case insufficientDisk(available: Int64, required: Int64)
    var errorDescription: String? {
        switch self {
        case .invalidReserve: return "VOX_ASR_MIN_FREE_DISK_BYTES must be a nonnegative integer."
        case .resourceQueryFailed: return "Cannot check temporary-volume free disk space; native preparation has not started for this stage."
        case .criticalMemoryPressure: return "Native preparation paused before this stage because memory pressure is critical. Close other work, then explicitly retry preparation."
        case .insufficientDisk(let available, let required):
            return "Native preparation needs its configured temporary-volume disk reserve (\(required) bytes; \(available) available). Free disk space, then explicitly retry preparation. Core ML has not started for this stage."
        }
    }
}
