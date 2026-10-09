# Node hello

Talks to Vox on your Mac from Bun or Node: transcribes a file, then speaks one line to `hello.wav`.

```bash
open -a Vox              # or: vox daemon start
bun install
bun run index.ts path/to/audio.wav
afplay hello.wav
```

Without a file argument it only speaks. Timings for each call land in `~/.vox/performance.jsonl` under the client id `vox-node-hello`; see them with `vox perf dashboard --client vox-node-hello`.

Outside this repo, depend on `@voxd/sdk` from npm instead of the `file:` path.
