# Annotation staging in an iOS app sandbox

## Log and reproduce

Talkie's real hosted iOS consumer failed three public `RemoteAnnotationProvider`
fixture cases at baseline Vox `8a5285d`: sequential scoped Scribe accounts,
request-owned cancellation and reflected HTTP 401. Native module compilation,
TTS fixtures and annotation oversize rejection passed. No annotation HTTP request
was observed, so a successful macOS fixture was not sufficient iOS evidence.

The first Talkie run (`41166738266`, consumer `40271433`) sanitized errors to
`requestFailed`. The diagnostic rerun (`41167475282`, consumer `21ea63c5`) retained
only error type/numeric code and reported **POSIX errno 13 (EACCES)** for annotation
staging, before HTTP. No request, credential, vendor body or private path was added
to those diagnostics.

## Trace and actual cause

`AnnotationUploadFile` used `VoxPrivateFiles.prepareDirectory` after resolving its
temporary URL. That helper is designed for same-user daemon capabilities, not
app-container temporary files. It opens filesystem root and validates/creates each
ancestor before reaching the destination. A valid app temporary-directory grant
does not imply permission to enumerate/operate on every ancestor, or that each
OS-managed ancestor meets this helper's capability-file mode policy.

The raw POSIX error originates from that capability helper, not a vendor status,
credential failure, model load, oversized source or response parser. Its coalesced
EACCES does not establish which particular ancestor operation/mode check rejected
the hosted container. Do not claim that a specific mkdir or OS sandbox rule was
isolated by that numeric code alone.

A deterministic native regression creates an explicitly granted temporary scope
beneath an ancestor that fails capability-file policy. The old capability helper
continues to reject it. The annotation-specific scoped staging succeeds without
changing ancestor permissions. This separates the two trust contracts instead of
relaxing the daemon's policy to make uploads pass.

## Fix and API

The public caller API is unchanged:

```swift
let result = try await AnnotationManager().annotate(request: AnnotationRequest(
    url: finalizedFileURL, modelId: "elevenlabs:scribe_v2",
    providerCredentials: ["ELEVENLABS_API_KEY": selectedKey]
))
```

The app owns readable finalized input and any external-file security-scoped access.
Vox owns staging. No directory override, hardcoded container path, permission repair
or vendor implementation belongs in Talkie.

The new internal annotation staging helper:

- Opens the existing OS-provided temporary-directory grant directly. It does not
  resolve/traverse/create/chmod filesystem ancestors or reuse the capability writer.
- Validates the opened root and creates only a UUID-named exclusive leaf, mode 0700.
  Mobile relies on the app-container grant, not ancestry mode policy. Desktop also
  refuses a writable, non-sticky shared temporary root. No root is chmodded.
- Creates `upload.bin` relative to the owned leaf descriptor with O_EXCL/O_NOFOLLOW,
  same-user regular-file/link-count checks and mode 0600. Never adopts a preexisting
  payload or follows its symlink.
- Keeps parent/leaf descriptors for idempotent cleanup. It unlinks only its payload
  and removes the matching inode/device leaf entry, never recursively deleting a
  replacement path. Cleanup errors can leave private residue, not justify deleting
  unrelated files. Abandoning the helper also attempts cleanup.
- Logs fixed staging phase identifiers and numeric errno on failure, never paths,
  media, requests, credentials or raw upstream error descriptions.

`VoxPrivateFiles` and private daemon capability ownership, permissions, traversal,
publication, peer checks and authentication are **unchanged**. Input-source no-follow
checks and changed-file detection remain. Limits are still 2,000,000,000 input bytes,
64 KiB copy chunks, two active requests, 4 MiB response and 8 MiB result. No upload
cache, retries or credential fallback is introduced.

## Verify with an actual iOS consumer

`examples/annotation-sandbox` is a standalone hosted iOS XCTest app importing only
public VoxCore/VoxEngine APIs. The new CI job runs `scripts/test-ios-annotation.py`.
It creates its own ephemeral Simulator and a loopback HTTP server, installs only
its disposable test host there, then shuts down/deletes only that owned Simulator.
It never runs on an operator device or changes installed applications/daemons.
The test host's local HTTP ATS exception is fixture-only, not a production change.

The tests use real `URLSessionUploadTask(fromFile:)`, sandbox staging and loopback
HTTP, not compilation-only or mocked URLProtocol evidence:

- Two scoped accounts, exact multipart fields, sanitized filename and vendor
  speaker/word/log-probability/audio-event mapping.
- Concurrent requests A/B; A cancellation closes only A's HTTP connection, B
  completes; actual 0700/0600 staging modes and terminal cleanup.
- Reflected synthetic-key HTTP 401 remains a typed status-only error and cleans up.
- A sparse oversized file rejects before HTTP/staging without copying gigabytes.

Local native validation: **280 Swift Testing cases** plus XCTest suites and
**28 strict cooperative focused cases** pass. Six new storage regressions cover
scope-vs-ancestry policy, private exclusive creation, symlink refusal, replacement
path preservation, idempotent cleanup and reference-release cleanup. The strict
private-capability regression tests still pass unchanged. The Xcode project is
successfully generated/resolved locally without launching a Simulator.

The mandatory hosted-iOS CI check supplies runtime evidence separately from those
native tests. No physical-device acceptance, live vendor access, vendor retention
or billing cancellation guarantee is implied. All media/keys are synthetic. No
operator Simulator/device was launched, no paid call/model inference occurred,
and no installed service, release or merge was performed for this investigation.
