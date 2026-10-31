# API Facts

- do not copy public type shapes without checking `packages/client/src/types.ts`
- companion RPC dispatch is canonical in `swift/Sources/VoxService/VoxRuntimeService.swift`
- current file routes: `transcribe.file`, `annotate.file`, `synthesize.generate`
- warm-up routes: `warmup.status`, `warmup.start`, `warmup.schedule`
- live transcription has start, status, stop, and cancel routes
- synthesis has voices, generate, session start, status, and cancel routes
- `createLiveSession()` is synchronous and returns `VoxLiveSession`
- synthesis options include optional speech timing and allowlisted OpenAI/ElevenLabs/NVIDIA/Groq/Gemini credentials; MiniMax keys are not lent per-request
- performance samples preserve `clientId`, `route`, `modelId`, and optional `voiceId`

- Native PCM routes: transcribe.stream.start|append|finish|cancel|status, separate from microphone startSession. See runtime brief for full identity/sequence/PCM contract.
- SDK: startPCMStream, appendPCMStream, finishPCMStream, cancelPCMStream, nativeStreamingStatus.

- annotation.models lists elevenlabs:scribe_v2 and deepgram:nova-3 capability/credential requirements; annotate.file requires explicit cloud ID and selected request key. See runtime brief for options/null scores/events/provenance/limits; no implicit cloud default, no ambient key fallback.

- Voice metadata adds optional quality: standard/enhanced/premium. Native Apple provider maps actual AVSpeechSynthesisVoice.quality (.default→standard); other backends and unknown platform cases omit it. Never infer from names/IDs or treat absent/null as standard. IDs/language/available/default selection remain unchanged. Swift TTSVoiceInfo.quality: TTSVoiceQuality?; older data and future unknown strings decode nil.
