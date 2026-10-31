@preconcurrency import CoreML
import Foundation
import VoxCore

/// Mutable caches belong to exactly one session. All calls are serialized by NativeStreamingASR.
/// No Core ML objects or tensor buffers escape that actor.
protocol StreamingPipeline: Sendable {
  var spec: StreamingModelSpec { get }
  var placement: CoreMLPlacement { get }
  var receivedSamples: Int { get }
  func reset() throws
  func prime() throws
  func append(_ samples: [Float]) throws -> [StreamingASRUpdate]
  func finish() throws -> StreamingASRUpdate
}

final class StreamingCoreMLPipeline: StreamingPipeline, @unchecked Sendable {
  let spec: StreamingModelSpec
  let placement: CoreMLPlacement
  private let encoder: MLModel
  private let preprocessor: MLModel
  private let decoder: MLModel?
  private let joint: MLModel
  private let vocabulary: [Int: String]
  private let blank: Int
  private var encoderState: [String: MLMultiArray] = [:]
  private var h: MLMultiArray
  private var c: MLMultiArray
  private var lastToken: Int
  private var melCache: MLMultiArray?
  private var tokens: [(piece: String, time: Double, confidence: Float)] = []
  private var audio: [Float] = []
  private(set) var receivedSamples = 0
  private var processedSamples = 0
  private var consumedSamples = 0
  private var audioStartSample = 0
  private var decodedFrames = 0
  private var lastEmissionSample = 0
  private var endpointEmitted = false
  private let prompt: Int

  static func load(spec: StreamingModelSpec, directory: URL, language: String) async throws
    -> StreamingCoreMLPipeline
  {
    let (encoder, placement) = try await CoreMLPlacement.loadEncoder(
      url: directory.appendingPathComponent(spec.encoder), modelId: spec.id)
    let cpu = MLModelConfiguration()
    cpu.computeUnits = .cpuOnly
    // Flexible-shape DSP stays on CPU, never instantiate this front-end on ANE.
    let preprocessor = try MLModel(
      contentsOf: directory.appendingPathComponent(spec.preprocessor), configuration: cpu)
    // Tiny recurrent nets: CPU avoids ANE dispatch per emitted symbol.
    let decoder =
      (spec.isEOU || spec.isUnified)
      ? try MLModel(contentsOf: directory.appendingPathComponent(spec.decoder), configuration: cpu)
      : nil
    let joint = try MLModel(
      contentsOf: directory.appendingPathComponent(spec.joint), configuration: cpu)
    let vocabData = try Data(contentsOf: directory.appendingPathComponent(spec.vocabulary))
    guard let vocab = try JSONSerialization.jsonObject(with: vocabData) as? [String: String] else {
      throw StreamingASRError.unavailable("Invalid streaming vocabulary")
    }
    let vocabulary = Dictionary(
      uniqueKeysWithValues: vocab.compactMap { key, value in Int(key).map { ($0, value) } })
    var prompt = 0
    let blank: Int
    if spec.isEOU {
      blank = 1026
    } else {
      let metadata =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: directory.appendingPathComponent("metadata.json")))
        as? [String: Any] ?? [:]
      guard let id = metadata["blank_idx"] as? Int else {
        throw StreamingASRError.unavailable("Missing blank_idx metadata")
      }
      blank = id
      if let dictionary = metadata["prompt_dictionary"] as? [String: Int] {
        let latin = [
          "en", "en-US", "en-GB", "es", "es-ES", "es-US", "fr", "fr-FR", "fr-CA", "it", "it-IT",
          "pt", "pt-BR", "pt-PT", "de", "de-DE",
        ]
        guard spec.isUnified || latin.contains(language), let selected = dictionary[language] else {
          throw StreamingASRError.unavailable(
            "Latin streaming bundle does not support language: \(language)")
        }
        prompt = selected
      } else if !["en", "en-US", "en-GB"].contains(language) {
        throw StreamingASRError.unavailable("English streaming model requires English")
      }
    }
    return try StreamingCoreMLPipeline(
      spec: spec, encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
      vocabulary: vocabulary, blank: blank, placement: placement, prompt: prompt)
  }

  private init(
    spec: StreamingModelSpec, encoder: MLModel, preprocessor: MLModel, decoder: MLModel?,
    joint: MLModel, vocabulary: [Int: String], blank: Int, placement: CoreMLPlacement, prompt: Int
  ) throws {
    self.spec = spec
    self.encoder = encoder
    self.preprocessor = preprocessor
    self.decoder = decoder
    self.joint = joint
    self.vocabulary = vocabulary
    self.blank = blank
    self.lastToken = blank
    self.placement = placement
    self.prompt = prompt
    self.h = try Self.zeros(joint: decoder ?? joint, input: "h_in")
    self.c = try Self.zeros(joint: decoder ?? joint, input: "c_in")
    try reset()
  }

  func reset() throws {
    try autoreleasepool { try resetCaches() }
  }

  private func resetCaches() throws {
    encoderState.removeAll()
    melCache = nil
    audio.removeAll(keepingCapacity: false)
    tokens.removeAll(keepingCapacity: false)
    receivedSamples = 0
    processedSamples = 0
    consumedSamples = 0
    audioStartSample = 0
    decodedFrames = 0
    lastEmissionSample = 0
    endpointEmitted = false
    lastToken = blank
    h = try Self.zeros(joint: decoder ?? joint, input: "h_in")
    c = try Self.zeros(joint: decoder ?? joint, input: "c_in")
    for (name, description) in encoder.modelDescription.inputDescriptionsByName
    where name.contains("cache") {
      guard let constraint = description.multiArrayConstraint else { continue }
      encoderState[name] = try Self.array(shape: constraint.shape, type: constraint.dataType)
    }
  }

  /// Priming is explicit preload work, and must not seed the next utterance's caches.
  func prime() throws {
    _ = try append(Array(repeating: 0.001, count: spec.windowSamples))
    try reset()
  }

  func append(_ samples: [Float]) throws -> [StreamingASRUpdate] {
    audio.append(contentsOf: samples)
    receivedSamples += samples.count
    var updates: [StreamingASRUpdate] = []
    if spec.isUnified {
      while receivedSamples >= consumedSamples + (consumedSamples == 0 ? 8960 : spec.shiftSamples) {
        updates.append(try processUnified(final: false))
      }
      return updates
    }
    while audio.count >= spec.windowSamples {
      try Task.checkCancellation()
      let window = Array(audio.prefix(spec.windowSamples))
      updates.append(try process(window))
      audio.removeFirst(min(spec.shiftSamples, audio.count))
    }
    return updates
  }

  func finish() throws -> StreamingASRUpdate {
    if spec.isUnified {
      if receivedSamples > 0 { _ = try processUnified(final: true) }
      return snapshot(endpoint: false, source: nil, latency: 0)
    }
    // Overlap retained after the last full EOU window still contains undecoded tail audio.
    while processedSamples < receivedSamples {
      let window =
        Array(audio.prefix(spec.windowSamples))
        + Array(repeating: Float(0), count: max(0, spec.windowSamples - audio.count))
      _ = try process(Array(window.prefix(spec.windowSamples)))
      audio.removeFirst(min(spec.shiftSamples, audio.count))
    }
    return snapshot(endpoint: false, source: nil, latency: 0)
  }

  private func processUnified(final: Bool) throws -> StreamingASRUpdate {
    let next =
      final ? receivedSamples : consumedSamples + (consumedSamples == 0 ? 8960 : spec.shiftSamples)
    var start = max(0, next - spec.windowSamples)
    start += (1280 - start % 1280) % 1280
    let localStart = start - audioStartSample
    let validCount = next - start
    let window =
      Array(audio[localStart..<(localStart + validCount)])
      + Array(repeating: Float(0), count: spec.windowSamples - validCount)
    let update = try process(
      window, validSampleCount: validCount, frameBase: start / 1280, final: final)
    consumedSamples = next
    // Keep at most one encoder window, aligned on the model's 80 ms frame grid.
    let trim = max(0, start - audioStartSample)
    audio.removeFirst(trim)
    audioStartSample = start
    return update
  }

  private func process(
    _ samples: [Float], validSampleCount: Int? = nil, frameBase: Int = 0, final: Bool = false
  ) throws -> StreamingASRUpdate {
    // Swift cooperative executors do not promise an Objective-C autorelease-pool
    // drain between audio packets. Core ML's temporary providers/tensors must not
    // accumulate for the lifetime of the app or a long dictation task.
    try autoreleasepool {
      try processInPool(
        samples, validSampleCount: validSampleCount, frameBase: frameBase, final: final)
    }
  }

  private func processInPool(
    _ samples: [Float], validSampleCount: Int?, frameBase: Int, final: Bool
  ) throws -> StreamingASRUpdate {
    let started = ContinuousClock.now
    let pcm = try Self.array(shape: [1, NSNumber(value: samples.count)])
    samples.withUnsafeBufferPointer { source in
      if let base = source.baseAddress {
        pcm.dataPointer.copyMemory(from: base, byteCount: source.count * MemoryLayout<Float>.stride)
      }
    }
    let melOutput = try preprocessor.prediction(
      from: MLDictionaryFeatureProvider(dictionary: [
        spec.isEOU ? "audio_signal" : "audio": pcm, "audio_length": try Self.scalar(samples.count),
      ]))
    let mel = try Self.output(melOutput, "mel")
    let melLength = try Self.output(melOutput, "mel_length")
    var inputs = encoderState
    if spec.isUnified {
      let validFrames = (validSampleCount ?? samples.count) / 160
      let totalFrames = mel.shape[2].intValue
      // NeMo per_feature normalization, with unbiased variance over valid audio only.
      // DSP remains in the Core ML front-end; no custom resampling or denoising.
      guard mel.dataType == .float32 else {
        throw StreamingASRError.unavailable("Expected float32 mel features")
      }
      let values = mel.dataPointer.assumingMemoryBound(to: Float.self)
      let binStride = mel.strides[1].intValue
      let timeStride = mel.strides[2].intValue
      for m in 0..<128 {
        let base = m * binStride
        var mean: Float = 0
        for t in 0..<validFrames { mean += values[base + t * timeStride] }
        mean /= Float(max(1, validFrames))
        var variance: Float = 0
        for t in 0..<validFrames {
          let delta = values[base + t * timeStride] - mean
          variance += delta * delta
        }
        let std = sqrt(variance / Float(max(1, validFrames - 1))) + 1e-5
        for t in 0..<totalFrames {
          let index = base + t * timeStride
          values[index] = t < validFrames ? (values[index] - mean) / std : 0
        }
      }
      inputs["mel"] = mel
      inputs["mel_length"] = try Self.scalar(validFrames)
      inputs["prompt_id"] = try Self.scalar(prompt)
    } else if spec.isEOU {
      inputs["audio_signal"] = mel
      inputs["audio_length"] = melLength
    } else {
      let shape = encoder.modelDescription.inputDescriptionsByName["mel"]!.multiArrayConstraint!
        .shape
      let combined = try Self.array(shape: shape)
      let count = shape[2].intValue
      let newFrames = spec.shiftSamples / 160
      let cacheFrames = count - newFrames
      guard mel.dataType == .float32 else {
        throw StreamingASRError.unavailable("Expected float32 mel features")
      }
      let source = mel.dataPointer.assumingMemoryBound(to: Float.self)
      let destination = combined.dataPointer.assumingMemoryBound(to: Float.self)
      let sourceBinStride = mel.strides[1].intValue
      let sourceTimeStride = mel.strides[2].intValue
      let destinationBinStride = combined.strides[1].intValue
      for m in 0..<128 {
        for t in 0..<cacheFrames {
          if let previous = melCache {
            let cachePointer = previous.dataPointer.assumingMemoryBound(to: Float.self)
            destination[m * destinationBinStride + t] =
              cachePointer[m * previous.strides[1].intValue + t * previous.strides[2].intValue]
          }
        }
        for t in 0..<newFrames {
          destination[m * destinationBinStride + t + cacheFrames] =
            source[m * sourceBinStride + t * sourceTimeStride]
        }
      }
      let cache = try Self.array(shape: [1, 128, NSNumber(value: cacheFrames)])
      let cachePointer = cache.dataPointer.assumingMemoryBound(to: Float.self)
      let start = mel.shape[2].intValue - cacheFrames
      for m in 0..<128 {
        for t in 0..<cacheFrames {
          cachePointer[m * cacheFrames + t] =
            source[m * sourceBinStride + (start + t) * sourceTimeStride]
        }
      }
      melCache = cache
      inputs["mel"] = combined
      inputs["mel_length"] = try Self.scalar(count)
      if encoder.modelDescription.inputDescriptionsByName["prompt_id"] != nil {
        inputs["prompt_id"] = try Self.scalar(prompt)
      }
    }
    let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    for key in encoderState.keys {
      let outputName: String
      if spec.isEOU {
        outputName = key == "pre_cache" ? "new_pre_cache" : "new_" + key
      } else {
        outputName = key + "_out"
      }
      encoderState[key] = try Self.output(output, outputName)
    }
    let encoded = try Self.output(
      output, spec.isUnified ? "encoder" : (spec.isEOU ? "encoded_output" : "encoded"))
    // Detect the known Core ML all-zero encoder failure, not just a successful prediction call.
    let nonZero =
      encoded.dataType == .float32
      ? (0..<encoded.count).contains {
        encoded.dataPointer.assumingMemoryBound(to: Float.self)[$0] != 0
      }
      : (0..<encoded.count).contains { encoded[$0].floatValue != 0 }
    guard nonZero else {
      throw StreamingASRError.unavailable(
        "Encoder returned all zeros; ANE program did not instantiate")
    }
    let oldCount = tokens.count
    var modelEndpoint = false
    let frames: Int
    let firstFrame: Int
    if spec.isUnified {
      let encodedLength = min(
        try Self.output(output, "encoder_length")[0].intValue, encoded.shape[2].intValue)
      firstFrame = max(0, decodedFrames - frameBase)
      frames = max(firstFrame, encodedLength - (final ? 0 : 5))
    } else {
      firstFrame = 0
      frames = min(spec.validFrames, encoded.shape[2].intValue)
    }
    let frameSeconds = Double(spec.shiftSamples) / 16000 / Double(spec.validFrames)
    decodeFrames: for t in firstFrame..<frames {
      let enc = try Self.array(shape: [1, encoded.shape[1], 1])
      if encoded.dataType == .float32 {
        let source = encoded.dataPointer.assumingMemoryBound(to: Float.self)
        let destination = enc.dataPointer.assumingMemoryBound(to: Float.self)
        for dim in 0..<encoded.shape[1].intValue {
          destination[dim] =
            source[dim * encoded.strides[1].intValue + t * encoded.strides[2].intValue]
        }
      } else {
        for dim in 0..<encoded.shape[1].intValue {
          enc[[0, NSNumber(value: dim), 0]] =
            encoded[[0, NSNumber(value: dim), NSNumber(value: t)]]
        }
      }
      for _ in 0..<10 {
        let token = try Self.array(shape: [1, 1], type: .int32)
        token[0] = NSNumber(value: lastToken)
        let prediction: MLFeatureProvider
        var nextH: MLMultiArray
        var nextC: MLMultiArray
        if let decoder {
          let decoded = try decoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
              "targets": token, "target_length": try Self.scalar(1), "h_in": h, "c_in": c,
            ]))
          prediction = try joint.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
              "encoder_step": enc, "decoder_step": try Self.output(decoded, "decoder"),
            ]))
          nextH = try Self.output(decoded, "h_out")
          nextC = try Self.output(decoded, "c_out")
        } else {
          prediction = try joint.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [
              "encoder": enc, "token": token, "token_length": try Self.scalar(1), "h_in": h,
              "c_in": c,
            ]))
          nextH = try Self.output(prediction, "h_out")
          nextC = try Self.output(prediction, "c_out")
        }
        let id: Int
        let confidence: Float
        if decoder != nil {
          id = try Self.output(prediction, "token_id")[0].intValue
          confidence = try Self.output(prediction, "token_prob")[0].floatValue
        } else {
          let logits = try Self.output(prediction, "logits")
          guard logits.dataType == .float32 else {
            throw StreamingASRError.unavailable("Expected float32 logits")
          }
          let values = logits.dataPointer.assumingMemoryBound(to: Float.self)
          var best = 0
          for i in 1..<logits.count where values[i] > values[best] { best = i }
          id = best
          let maximum = Double(values[best])
          var sum = 0.0
          for i in 0..<logits.count { sum += exp(Double(values[i]) - maximum) }
          confidence = Float(1 / sum)
        }
        if id == blank { break }
        if spec.isEOU && id == 1024 {
          modelEndpoint = true
          break decodeFrames
        }
        lastToken = id
        h = nextH
        c = nextC
        if spec.isEOU && id == 1025 { continue }
        if let piece = vocabulary[id], !piece.hasPrefix("<") {
          let time =
            spec.isUnified
            ? Double(frameBase + t) * 0.08
            : Double(processedSamples) / 16000 + Double(t) * frameSeconds
          tokens.append((piece, time, confidence))
          lastEmissionSample = Int(time * 16000)
        }
      }
    }
    if spec.isUnified {
      decodedFrames = frameBase + frames
      processedSamples = decodedFrames * 1280
    } else {
      processedSamples += spec.shiftSamples
    }
    if tokens.count > oldCount { endpointEmitted = false }
    let blankEndpoint =
      !spec.isEOU && !tokens.isEmpty && processedSamples - lastEmissionSample >= 17920
    let endpoint = !endpointEmitted && (modelEndpoint || blankEndpoint) && !tokens.isEmpty
    if endpoint { endpointEmitted = true }
    let elapsed = started.duration(to: .now)
    let latency =
      Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return snapshot(
      endpoint: endpoint, source: endpoint ? (spec.isEOU ? "model" : "blank-duration") : nil,
      latency: latency)
  }

  private func snapshot(endpoint: Bool, source: String?, latency: Double) -> StreamingASRUpdate {
    let duration = Double(receivedSamples) / 16000
    var words: [WordTiming] = []
    var word = ""
    var start = 0.0
    var end = 0.0
    var confidence: Float = 1
    func commit() {
      guard !word.isEmpty else { return }
      words.append(
        WordTiming(
          word: word, start: min(start, duration), end: min(max(start, end), duration),
          confidence: confidence))
    }
    for token in tokens {
      if token.piece.contains("▁") {
        commit()
        word = token.piece.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(
          in: .whitespaces)
        start = token.time
        confidence = token.confidence
      } else {
        if word.isEmpty {
          start = token.time
          confidence = token.confidence
        }
        word += token.piece
        confidence = min(confidence, token.confidence)
      }
      end = token.time + Double(spec.shiftSamples) / 16000 / Double(spec.validFrames)
    }
    commit()
    let text = tokens.map(\.piece).joined().replacingOccurrences(of: "▁", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return StreamingASRUpdate(
      text: text, words: words, endOfUtterance: endpoint, endpointSource: source,
      processedAudioMs: min(receivedSamples, processedSamples) / 16, chunkLatencyMs: latency)
  }

  private static func zeros(joint: MLModel, input: String) throws -> MLMultiArray {
    guard
      let constraint = joint.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint
    else { throw StreamingASRError.unavailable("Missing model input: \(input)") }
    return try array(shape: constraint.shape, type: constraint.dataType)
  }
  private static func array(shape: [NSNumber], type: MLMultiArrayDataType = .float32) throws
    -> MLMultiArray
  {
    let array = try MLMultiArray(shape: shape, dataType: type)
    memset(array.dataPointer, 0, array.count * (type == .float16 ? 2 : 4))
    return array
  }
  private static func scalar(_ value: Int) throws -> MLMultiArray {
    let array = try array(shape: [1], type: .int32)
    array[0] = NSNumber(value: value)
    return array
  }
  private static func output(_ provider: MLFeatureProvider, _ key: String) throws -> MLMultiArray {
    guard let array = provider.featureValue(for: key)?.multiArrayValue else {
      throw StreamingASRError.unavailable("Missing model output: \(key)")
    }
    return array
  }
}
