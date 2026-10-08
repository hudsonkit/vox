import { chmodSync, copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const target = "aarch64-apple-darwin";
const platform = "darwin-arm64";
const bundles = [{ id: "whistle", executable: "vox-whistle" }];

if (process.platform !== "darwin") {
  throw new Error("Build the Apple Silicon provider bundles on macOS with the Apple SDK installed.");
}

for (const bundle of bundles) {
  const build = Bun.spawnSync([
    "cargo", "build", "--manifest-path", join(root, "providers/Cargo.toml"),
    "--locked", "--release", "--target", target, "--package", bundle.executable,
  ], { cwd: root, stdout: "inherit", stderr: "inherit" });
  if (build.exitCode !== 0) throw new Error(`Failed to build ${bundle.id}. Install Rust and target ${target}.`);
  const source = join(root, "providers/target", target, "release", bundle.executable);
  const output = join(root, "packages/cli/plugins", bundle.id, "bin", platform, bundle.executable);
  mkdirSync(dirname(output), { recursive: true });
  copyFileSync(source, output);
  chmodSync(output, 0o755);
  const sign = Bun.spawnSync(["/usr/bin/codesign", "--force", "--sign", "-", output], {
    stdout: "inherit", stderr: "inherit",
  });
  if (sign.exitCode !== 0) throw new Error(`Failed to ad-hoc sign ${bundle.id}.`);
  console.log(`Built ${bundle.id}: ${output}`);
}
