# SDK Facts

- companion client entrypoint: `packages/client/src/client.ts`
- metrics parser: `packages/client/src/metrics.ts`
- companion client only: Apple apps should embed Swift packages directly instead
- core result types:
  - `FileTranscriptionResult`
  - `FileAnnotationResult`
  - `SynthesisResult`
- voice metadata type: `VoiceInfo`
- warmup methods exposed: `getWarmupStatus`, `startWarmup`, `scheduleWarmup`
- synthesis methods exposed: `listVoices`, `synthesize`
- ASR method exposed: `transcribeFile`
- catalog methods exposed: `listCatalog`, `refreshCatalog`
- annotation method exposed: `annotateFile`
- live session method exposed: `createLiveSession`; it returns `VoxLiveSession` synchronously
- synthesis can return optional `speechTiming`; read the types in `packages/client/src/types.ts` before duplicating shapes
- per-request `credentials` are allowlisted for OpenAI, ElevenLabs, NVIDIA Magpie, Groq, and Gemini/Google

- Native PCM: preloadModel explicitly, startPCMStream(modelId), appendPCMStream(sessionId,sequence,Float32Array) -> nextSequence+updates, finishPCMStream -> final update, cancelPCMStream -> discard, nativeStreamingStatus.
- 1–16000 finite mono 16 kHz samples; await each packet acknowledgement; no uncertain retries; cumulative text + approximate word timestamps + endpointSource.

- listVoices(modelId, credentials?) forwards selected-account credentials on that call only; explicit model required with keys. ElevenLabs dynamic voices and OpenAI static catalog support this; other unsupported providers error. Never log credentials; inventory availability stays daemon-configured, not borrowed-account state.

- listAnnotationModels + annotateFile(path, AnnotationOptions) with required explicit modelId, scoped credentials.ELEVENLABS_API_KEY / DEEPGRAM_API_KEY, diarize/tagAudioEvents/languageCode/numSpeakers; timeoutMs default3600000. Nullable confidence, raw logProbability, speakerConfidence; preserve audioEvents, language/duration/provenance and unsupported/unavailable fields. See runtime brief. TS transport remains TCP-only.
