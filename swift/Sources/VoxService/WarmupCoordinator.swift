import Foundation
import VoxCore
import HudsonSpeechEngine

actor WarmupCoordinator {
    enum WarmupState: String {
        case idle
        case scheduled
        case warming
        case ready
        case failed
    }

    private struct Record {
        var state: WarmupState = .idle
        var requestedBy: String?
        var scheduledFor: Date?
        var startedAt: Date?
        var completedAt: Date?
        var lastError: String?
    }

    private let log = VoxLog.service
    private let asrEngine: EngineManager
    private let ttsEngine: TTSEngineManager
    private var records: [String: Record] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var scheduledTasks: [String: Task<Void, Never>] = [:]

    init(asrEngine: EngineManager, ttsEngine: TTSEngineManager) {
        self.asrEngine = asrEngine
        self.ttsEngine = ttsEngine
    }

    func start(modelId: String, requestedBy: String?) async -> WarmupStatus {
        cancelScheduledWarmup(for: modelId)

        if let record = records[modelId], record.state == .warming {
            return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
        }

        if await isModelPreloaded(modelId: modelId) {
            var record = records[modelId] ?? Record()
            record.state = .ready
            record.requestedBy = requestedBy ?? record.requestedBy
            if record.completedAt == nil {
                record.completedAt = Date()
            }
            record.lastError = nil
            records[modelId] = record
            return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
        }

        beginWarmup(modelId: modelId, requestedBy: requestedBy)
        return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
    }

    func schedule(modelId: String, delayMs: Int, requestedBy: String?) async -> WarmupStatus {
        guard delayMs > 0 else {
            return await start(modelId: modelId, requestedBy: requestedBy)
        }

        cancelScheduledWarmup(for: modelId)
        if let record = records[modelId], record.state == .warming {
            return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
        }

        if await isModelPreloaded(modelId: modelId) {
            var record = records[modelId] ?? Record()
            record.state = .ready
            record.requestedBy = requestedBy ?? record.requestedBy
            if record.completedAt == nil {
                record.completedAt = Date()
            }
            record.lastError = nil
            records[modelId] = record
            return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
        }

        let scheduledFor = Date().addingTimeInterval(Double(delayMs) / 1000)
        var record = records[modelId] ?? Record()
        record.state = .scheduled
        record.requestedBy = requestedBy
        record.scheduledFor = scheduledFor
        record.lastError = nil
        records[modelId] = record

        scheduledTasks[modelId] = Task {
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled else { return }
            self.beginWarmup(modelId: modelId, requestedBy: requestedBy)
        }

        log.info("Scheduled warmup for \(modelId) in \(delayMs)ms")
        return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
    }

    func status(modelId: String, requestedBy: String? = nil) async -> WarmupStatus {
        if await isModelPreloaded(modelId: modelId) {
            var record = records[modelId] ?? Record()
            record.state = .ready
            record.requestedBy = requestedBy ?? record.requestedBy
            if record.completedAt == nil {
                record.completedAt = Date()
            }
            record.lastError = nil
            records[modelId] = record
        } else if var record = records[modelId], record.state == .ready {
            record.state = .idle
            records[modelId] = record
        }

        return snapshot(modelId: modelId, fallbackRequestedBy: requestedBy)
    }

    private func beginWarmup(modelId: String, requestedBy: String?) {
        cancelScheduledWarmup(for: modelId)
        if activeTasks[modelId] != nil {
            return
        }

        var record = records[modelId] ?? Record()
        record.state = .warming
        record.requestedBy = requestedBy ?? record.requestedBy
        record.scheduledFor = nil
        record.startedAt = Date()
        record.completedAt = nil
        record.lastError = nil
        records[modelId] = record

        log.info("Starting warmup for \(modelId)")
        activeTasks[modelId] = Task {
            do {
                if await self.isTTSModel(modelId: modelId) {
                    _ = try await self.ttsEngine.preload(modelId: modelId) { _ in }
                } else {
                    _ = try await self.asrEngine.preload(modelId: modelId) { _ in }
                }
                self.finishWarmup(modelId: modelId, error: nil)
            } catch {
                self.finishWarmup(modelId: modelId, error: error.localizedDescription)
            }
        }
    }

    private func finishWarmup(modelId: String, error: String?) {
        activeTasks[modelId] = nil

        var record = records[modelId] ?? Record()
        record.completedAt = Date()
        if let error {
            record.state = .failed
            record.lastError = error
            log.error("Warmup failed for \(modelId): \(error)")
        } else {
            record.state = .ready
            record.lastError = nil
            log.info("Warmup ready for \(modelId)")
        }
        records[modelId] = record
    }

    private func cancelScheduledWarmup(for modelId: String) {
        scheduledTasks[modelId]?.cancel()
        scheduledTasks[modelId] = nil
    }

    private func snapshot(modelId: String, fallbackRequestedBy: String?) -> WarmupStatus {
        let record = records[modelId] ?? Record()
        return WarmupStatus(
            modelId: modelId,
            state: record.state.rawValue,
            requestedBy: record.requestedBy ?? fallbackRequestedBy,
            scheduledFor: record.scheduledFor,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            lastError: record.lastError
        )
    }

    private func isModelPreloaded(modelId: String) async -> Bool {
        let ttsModels = await ttsEngine.models()
        if let model = ttsModels.first(where: { $0.id == modelId }) {
            return model.preloaded
        }

        let asrModels = await asrEngine.models()
        return asrModels.first(where: { $0.id == modelId })?.preloaded ?? false
    }

    private func isTTSModel(modelId: String) async -> Bool {
        let models = await ttsEngine.models()
        return models.contains(where: { $0.id == modelId })
    }
}
