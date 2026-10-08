import { accessSync, constants, lstatSync, readdirSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

const plugins = join(dirname(dirname(fileURLToPath(import.meta.url))), "plugins");
for (const entry of readdirSync(plugins, { withFileTypes: true })) {
  if (!entry.isDirectory() || entry.name === "shared") continue;
  const directory = join(plugins, entry.name);
  const manifest = JSON.parse(readFileSync(join(directory, "bundle.json"), "utf8"));
  for (const [platform, executable] of Object.entries(manifest.executables ?? {})) {
    if (typeof executable !== "string" || isAbsolute(executable) || executable.includes("\\")
        || executable.split("/").some((part) => !part || part === "." || part === "..")) {
      throw new Error(`Invalid bundled executable path: ${executable}`);
    }
    const path = join(directory, executable);
    try {
      let component = directory;
      for (const part of executable.split("/")) {
        component = join(component, part);
        if (lstatSync(component).isSymbolicLink()) throw new Error("symlink in executable path");
      }
      const stat = lstatSync(path);
      if (!stat.isFile() || stat.size === 0) throw new Error("not a nonempty regular file");
      accessSync(path, constants.X_OK);
    } catch (error) {
      throw new Error(`Missing executable for ${entry.name} (${platform}). Run bun run build:providers before packaging.`, { cause: error });
    }
  }
}
