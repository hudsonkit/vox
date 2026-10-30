import Foundation
import VoxCore

/// A single process-wide ASR model slot. A session/operation holds a lease; model switching
/// evicts the previous runtime before a new encoder is loaded. It never steals a live lease.
actor NativeASRResidency {
  static let shared = NativeASRResidency()
  private var active: UUID?
  private var resident: (id: String, unload: @Sendable () async -> Void)?

  func acquire(modelId: String, unload: @escaping @Sendable () async -> Void) async throws -> UUID {
    guard active == nil else { throw StreamingASRError.busy }
    let lease = UUID()
    active = lease
    if let previous = resident, previous.id != modelId {
      resident = nil
      await previous.unload()
    }
    resident = (modelId, unload)
    return lease
  }
  func release(_ lease: UUID) {
    if active == lease { active = nil }
  }
}
