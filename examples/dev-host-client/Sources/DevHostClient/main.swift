import AVFoundation
import Foundation
import VoxClient

let args = CommandLine.arguments
func output(_ value: JSONValue) throws { print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
let counts = ["health": 2, "models": 2, "install": 3, "prepare": 3, "file": 4, "stream": 4, "cycle": 4]
guard args.count > 1, let count = counts[args[1]], args.count >= count else {
    FileHandle.standardError.write(Data("Usage: DevHostClient health|models|install ID|prepare ID|file ID PATH|stream ID PATH|cycle ID PATH [--paced]\n".utf8))
    exit(64)
}
let client = VoxDaemonClient(clientId: "vox-dev-host-client")
func model(_ id: String) async throws -> JSONValue? {
    guard case .array(let models) = try await client.listModels()["models"] else { return nil }
    return models.first { $0["id"]?.stringValue == id }
}
func prepare(_ id: String) async throws -> JSONValue {
    try await client.preloadModel(id, timeout: .seconds(600)) { event in
        if let data = try? JSONEncoder().encode(event.data) {
            FileHandle.standardError.write(data);FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
func inference(_ id: String, _ path: String) async throws -> JSONValue {
    if id == "parakeet:v3" {
        return try await client.call("transcribe.file", params: ["modelId": .string(id), "path": .string(path)], timeout: .seconds(120))
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
        fatalError("Streaming probe needs mono 16 kHz WAV")
    }
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let session = try await client.startPCMStream(modelId: id)
    var sequence = 0
    let started = Date();var firstPartialMs: Double?;var updateCount = 0
    do {
        for offset in stride(from: 0, to: samples.count, by: 1280) {
            if args.contains("--paced") {
                let delay = Double(min(offset + 1280, samples.count)) / 16000 - Date().timeIntervalSince(started)
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            }
            let ack = try await client.appendPCMStream(sessionId: session.sessionId, sequence: sequence,
                samples: Array(samples[offset..<min(offset + 1280, samples.count)]))
            sequence = ack.nextSequence
            for update in ack.updates where !update.text.isEmpty {
                updateCount += 1
                if firstPartialMs == nil { firstPartialMs = Date().timeIntervalSince(started) * 1000 }
            }
        }
        let stop = Date()
        let final = try await client.finishPCMStream(sessionId: session.sessionId)
        return .object(["text": .string(final.text), "nonemptyUpdates": .number(Double(updateCount)),
            "firstPartialWallMs": firstPartialMs.map(JSONValue.number) ?? .null, "paced": .bool(args.contains("--paced")),
            "stopToFinalMs": .number(Date().timeIntervalSince(stop) * 1000),
            "result": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(final))])
    } catch {
        try? await client.cancelPCMStream(sessionId: session.sessionId)
        throw error
    }
}
do {
    try await client.connectDiscovered() // Explicit capability only; never launches or falls back.
    switch args[1] {
    case "health": try output(await client.call("health"))
    case "models": try output(await client.listModels())
    case "install": try output(await client.installModel(args[2]))
    case "prepare": try output(await prepare(args[2]))
    case "file", "stream": try output(await inference(args[2], args[3]))
    case "cycle":
        let id = args[2], path = args[3]
        guard try await model(id)?["installed"] == true else { fatalError("Existing model required; cycle never downloads") }
        var records: [JSONValue] = []
        for phase in ["initial", "after-idle"] {
            let start = Date()
            let ready = try await prepare(id)
            let prepareMs = Date().timeIntervalSince(start) * 1000
            let inferenceStart = Date()
            let result = try await inference(id, path)
            guard result["text"]?.stringValue?.isEmpty == false else { fatalError("Expected nonempty synthetic speech result") }
            records.append(.object(["phase": .string(phase), "prepareMs": .number(prepareMs), "ready": ready,
                "inferenceMs": .number(Date().timeIntervalSince(inferenceStart) * 1000), "inference": result]))
            if phase == "initial" {
                let deadline = Date().addingTimeInterval(1000)
                while try await model(id)?["preloaded"] == true {
                    guard Date() < deadline else { fatalError("No actual idle eviction observed") }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let unloaded = try await model(id)
                guard unloaded?["computePlacement"] == nil || unloaded?["computePlacement"] == .null else { fatalError("Placement survived eviction") }
            }
        }
        try output(.object(["modelId": .string(id), "records": .array(records)]))
    default: fatalError("Unknown dev client command")
    }
    await client.disconnect()
} catch {
    await client.disconnect()
    FileHandle.standardError.write(Data("Vox request failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
