# Real iOS annotation sandbox consumer

An independent, minimal iOS app hosts XCTest consumers of public `VoxCore` and
`VoxEngine`. The host has no application services, capture, playback or model load.
It does not import a Talkie adapter or provide library-private staging paths.

`python3 scripts/test-ios-annotation.py` is **CI-only** (`CI=true`). It requires
Xcode and XcodeGen, creates its own ephemeral Simulator, installs only this disposable
test host there, then shuts down/deletes only that owned Simulator. Do not run it
against an operator device or an installed app. No physical-device install, paid
vendor call, model download/load, daemon/launchd change or release is involved.

The script starts a loopback HTTP server and generates an ignored endpoint constant
before generating the ignored Xcode project. The fixture host alone allows insecure
local HTTP for this server. Production endpoint validation/ATS configuration is not
changed. Real URLSession file uploads cross the iOS app sandbox and HTTP boundary;
this is not a compilation-only or URLProtocol-only test.

Checks:

- Two explicit Scribe accounts, exact multipart fields and sanitized filename.
- Actual private staging directory/file modes (0700/0600) inside the app's OS temp
  grant, cleanup after success and errors, no source deletion.
- Concurrent A/B uploads: cancel A closes A's HTTP connection; B remains usable.
- A reflected synthetic-key 401 stays a typed status-only error.
- A sparse oversized source is rejected before HTTP/staging; no 2 GB copy is made.

All keys/audio/responses are synthetic. No transcript or credentials are printed.
The maximum input stays 2,000,000,000 bytes, response 4 MiB and result 8 MiB.
Two-request concurrency and 64 KiB copy bounds remain the production contract.
