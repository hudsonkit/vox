import AVFoundation
import Foundation
import VoxCore
import VoxEngine

let usage = """
usage: vox-embed-demo <command>

  warmup               download and load the speech model
  listen [seconds]     record from the microphone, then transcribe (default 5)
  transcribe <file>    transcribe an audio file
  speak <text>         synthesize and play speech

Set OPENAI_API_KEY to speak with gpt-4o-mini-tts instead of the system voice.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(1)
}

let dictation = VoxDictation(clientId: "vox-embed-demo")

func warmUp() async throws {
    let start = Date()
    try await dictation.warmUp { progress in
        print("  \(progress.status)", terminator: "\r")
    }
    print("ready in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
}

func show(_ output: TranscriptionOutput) {
    print(output.text)
    print("[\(output.modelId) · \(output.metrics.audioDurationMs) ms audio · \(output.metrics.totalMs) ms total]")
}

do {
    switch command {
    case "warmup":
        try await warmUp()

    case "listen":
        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 5 : 5
        try await warmUp()
        try await dictation.start()
        print("listening for \(Int(seconds))s…")
        try await Task.sleep(for: .seconds(seconds))
        show(try await dictation.stop())

    case "transcribe":
        guard arguments.count > 1 else { print(usage); exit(1) }
        try await warmUp()
        show(try await dictation.transcribe(fileURL: URL(fileURLWithPath: arguments[1])))

    case "speak":
        let text = arguments.dropFirst().joined(separator: " ")
        guard !text.isEmpty else { print(usage); exit(1) }
        let speech = makeSpeech(openAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        let output = try await speech.engine.synthesize(SynthesisRequest(text: text, modelId: speech.modelId))
        print("[\(output.modelId) · \(output.voiceId) · \(output.metrics.totalMs) ms]")
        let player = try AVAudioPlayer(data: output.audioData)
        player.play()
        try await Task.sleep(for: .seconds(player.duration + 0.2))

    default:
        print(usage)
        exit(1)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
