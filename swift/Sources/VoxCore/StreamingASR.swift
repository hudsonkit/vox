import Foundation

public enum StreamingASRError: Error, LocalizedError, Sendable {
  case unavailable(String)
  case busy
  case notReady
  case invalidSession
  case invalidAudio
  public var errorDescription: String? {
    switch self {
    case .unavailable(let detail): return detail
    case .busy:
      return "streaming_asr_busy: another session or model operation owns the native ASR runtime"
    case .notReady:
      return "streaming_asr_not_ready: install and explicitly preload the model before starting"
    case .invalidSession:
      return "streaming_asr_invalid_session: session does not belong to this caller or has ended"
    case .invalidAudio:
      return
        "streaming_asr_invalid_audio: expected finite mono 16 kHz float32 PCM, at most one second per append"
    }
  }
}

/// Cumulative text and approximate word timings, on the input-audio timeline.
/// Timings are greedy RNNT emission frames, not forced alignment.
public struct StreamingASRUpdate: Codable, Sendable, Equatable {
  public let text: String
  public let words: [WordTiming]
  public let endOfUtterance: Bool
  /// `model` for a trained EOU token, `blank-duration` for Nemotron endpointing.
  public let endpointSource: String?
  public let processedAudioMs: Int
  public let chunkLatencyMs: Double
  public init(
    text: String, words: [WordTiming], endOfUtterance: Bool, endpointSource: String?,
    processedAudioMs: Int, chunkLatencyMs: Double
  ) {
    self.text = text
    self.words = words
    self.endOfUtterance = endOfUtterance
    self.endpointSource = endpointSource
    self.processedAudioMs = processedAudioMs
    self.chunkLatencyMs = chunkLatencyMs
  }
}

public enum StreamingASRDefaults {
  public static let modelId = "nemotron:unified-560ms"
  // macOS measurements show ~100 MiB hot models but multi-minute, GiB-scale
  // preparation during an observed reload after eviction. Keep a bounded 15-minute desktop hot window.
  // iOS stays conservative until measured on physical devices.
  #if os(macOS)
  public static let idleUnloadSeconds: Double = 900
  #else
  public static let idleUnloadSeconds: Double = 60
  #endif
  public static func resolvedIdleUnloadSeconds(environment: [String: String]) -> Double {
    guard let raw = environment["VOX_ASR_IDLE_SECONDS"],
          let seconds = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          seconds.isFinite, seconds >= 0 else { return idleUnloadSeconds }
    return seconds
  }
}

public struct NativeStreamingStatus: Codable, Sendable, Equatable {
  public let modelId: String?
  public let loadingModelId: String?
  public let placement: CoreMLPlacement?
  public let activeSessionId: UUID?
  public let clientId: String?
  public let idleUnloadSeconds: Double
  public init(modelId: String? = nil, loadingModelId: String? = nil,
              placement: CoreMLPlacement? = nil, activeSessionId: UUID? = nil,
              clientId: String? = nil, idleUnloadSeconds: Double) {
    self.modelId = modelId
    self.loadingModelId = loadingModelId
    self.placement = placement
    self.activeSessionId = activeSessionId
    self.clientId = clientId
    self.idleUnloadSeconds = idleUnloadSeconds
  }
}
