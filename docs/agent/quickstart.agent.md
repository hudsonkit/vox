# Quickstart Facts

- Swift embed minimums: macOS 14+, iOS 17+
- Minivox direct-embed dictation app: `apps/minivox/`, macOS 26+
- packaged Vox menu app requires macOS 26+
- published CLI requires Node 22+
- install CLI: `npm install -g @voxd/cli`
- install Companion from the DMG before `vox install`, or provide `~/.vox/bin/voxd`
- verify with `vox doctor`
- repo checkout CLI after build: `node packages/cli/dist/index.js`
- ASR smoke path: `vox warmup start parakeet:v3` then `vox transcribe file <path>`
- catalog: `vox models catalog` then `vox models catalog refresh`
- plugins: `vox plugins list` then `vox plugins install mlx-vlm`
- do not send Apple-native integrations through Companion by default
