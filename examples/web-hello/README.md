# Web hello

A web page that uses Vox on your Mac: dictate from the Mac's microphone with live partial text, or drop in an audio file.

```bash
open -a Vox              # or: vox daemon start
bun install
bun run start            # http://localhost:3000
```

Vox only answers web pages whose origin it allows. Any `http://localhost` port is allowed out of the box. For your own domain, add it in Vox settings, or drop a file into `~/.vox/origins.d/`:

```json
{"origins":["https://app.example.com"]}
```

Outside this repo, depend on `@voxd/client` from npm instead of the `file:` path.
