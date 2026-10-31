import AVFoundation
import Darwin
import Foundation
import HudsonSpeechEngine
import VoxCore

func footprintMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_000_000 : -1
}

@main struct Benchmark {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("Benchmark failed: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let args = CommandLine.arguments
    if args.count > 1 && args[1] == "lifecycle" {
      try await NativeLifecycleBenchmark.run(arguments: args)
      return
    }
    guard args.count >= 4 else {
      print(
        "Usage: vox-asr-bench MODEL_ID MODEL_DIRECTORY AUDIO_16KHZ_MONO_WAV_OR_DIRECTORY [REFERENCE_TEXT_FILE] [--paced]"
      )
      return
    }
    let modelId = args[1]
    let input = URL(fileURLWithPath: args[3])
    let isDirectory = (try? input.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let inputs =
      isDirectory
      ? try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
      : [input]
    guard !inputs.isEmpty else { throw StreamingASRError.unavailable("No benchmark WAV inputs") }
    if modelId.hasPrefix("parakeet:v") {
      try await batch(modelId: modelId, inputs: inputs)
      return
    }
    let engine = NativeStreamingASR.shared
    try await engine.setIdleUnload(seconds: 0)
    let baseline = footprintMB()
    let loadStart = Date()
    _ = try await engine.preload(modelId: modelId, directory: URL(fileURLWithPath: args[2]))
    let loaded = footprintMB()
    let loadMs = Date().timeIntervalSince(loadStart) * 1000
    var dictations: [[String: Any]] = []
    for input in inputs {
      let file = try AVAudioFile(
        forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
      guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
      else {
        throw StreamingASRError.unavailable("Benchmark input must be 16 kHz mono WAV")
      }
      try file.read(into: buffer)
      let audio = Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
      let id = try await engine.begin(clientId: "vox-asr-bench", modelId: modelId)
      var latencies: [Double] = []
      var firstPartialAudioMs: Double?
      var firstPartialComputeMs: Double?
      var endpoints: [Int] = []
      let start = Date()
      // 80 ms capture packets; no pacing. Report input-audio latency separately from compute latency.
      for offset in stride(from: 0, to: audio.count, by: 1280) {
        if args.contains("--paced") {
          let target = Double(min(offset + 1280, audio.count)) / 16000
          let delay = target - Date().timeIntervalSince(start)
          if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
        let updates = try await engine.append(
          sessionId: id, clientId: "vox-asr-bench",
          samples: Array(audio[offset..<min(offset + 1280, audio.count)]))
        for update in updates {
          latencies.append(update.chunkLatencyMs)
          if !update.text.isEmpty && firstPartialAudioMs == nil {
            firstPartialAudioMs = Double(min(offset + 1280, audio.count)) / 16
            firstPartialComputeMs = Date().timeIntervalSince(start) * 1000
          }
          if update.endOfUtterance { endpoints.append(update.processedAudioMs) }
        }
      }
      let final = try await engine.finish(sessionId: id, clientId: "vox-asr-bench")
      let dictationMs = Date().timeIntervalSince(start) * 1000
      let after = footprintMB()
      var output: [String: Any] = [
        "input": input.lastPathComponent, "afterDictationMB": after, "dictationMs": dictationMs,
        "audioMs": Double(audio.count) / 16,
        "chunkLatencyMs": latencies,
        "chunkMeanMs": latencies.reduce(0, +) / Double(max(1, latencies.count)),
        "firstPartialAudioMs": firstPartialAudioMs as Any? ?? NSNull(),
        "firstPartialComputeMs": firstPartialComputeMs as Any? ?? NSNull(),
        "endpointsAudioMs": endpoints, "text": final.text,
        "words": final.words.map { $0.dictionaryValue() },
      ]
      let referenceURL =
        isDirectory
        ? input.deletingPathExtension().appendingPathExtension("txt")
        : (args.count >= 5 && args[4] != "--paced"
          ? URL(fileURLWithPath: args[4])
          : input.deletingPathExtension().appendingPathExtension("txt"))
      if FileManager.default.fileExists(atPath: referenceURL.path) {
        let reference = try String(contentsOf: referenceURL, encoding: .utf8)
        func words(_ string: String) -> [String] {
          string.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(
            String.init)
        }
        let expected = words(reference)
        let actual = words(final.text)
        var row = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
          var next = [i + 1] + Array(repeating: 0, count: actual.count)
          for (j, recognized) in actual.enumerated() {
            next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (word == recognized ? 0 : 1))
          }
          row = next
        }
        output["wordErrors"] = row.last!
        output["referenceWords"] = expected.count
        output["wer"] = Double(row.last!) / Double(max(1, expected.count))
      }
      dictations.append(output)
    }
    let status = try JSONSerialization.jsonObject(with: JSONEncoder().encode(await engine.status()))
    try await engine.unload()
    let output: [String: Any] = [
      "modelId": modelId, "baselineMB": baseline, "afterLoadMB": loaded,
      "afterUnloadMB": footprintMB(), "loadAndPrimeMs": loadMs, "paced": args.contains("--paced"),
      "status": status, "dictations": dictations,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }

  private static func batch(modelId: String, inputs: [URL]) async throws {
    let engine = EngineManager(provider: ParakeetProvider())
    guard await engine.models().contains(where: { $0.id == modelId && $0.installed }) else {
      throw StreamingASRError.unavailable(
        "Install the pinned batch model before benchmarking; batch model directory is resolved through VOX_HOME"
      )
    }
    let baseline = footprintMB()
    let start = Date()
    let info = try await engine.preload(modelId: modelId, progress: { _ in })
    let loaded = footprintMB()
    let loadMs = Date().timeIntervalSince(start) * 1000
    var results: [[String: Any]] = []
    for input in inputs {
      let output = try await engine.transcribe(url: input, modelId: modelId)
      results.append([
        "input": input.lastPathComponent, "text": output.text, "afterDictationMB": footprintMB(),
        "inferenceMs": output.metrics.inferenceMs, "audioMs": output.metrics.audioDurationMs,
      ])
    }
    let output: [String: Any] = [
      "modelId": modelId, "baselineMB": baseline, "afterLoadMB": loaded, "loadAndPrimeMs": loadMs,
      "status": info.dictionaryValue(), "dictations": results,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}
