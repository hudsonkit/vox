import { randomUUID } from "crypto";
import {
  accessSync, chmodSync, constants, existsSync, lstatSync, mkdirSync, mkdtempSync,
  readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "fs";
import { delimiter, dirname, isAbsolute, join, resolve } from "path";
import { fileURLToPath } from "url";
import { getVoxHome } from "@voxd/sdk";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_CATALOG_URL = "https://voxd.cc/data/models.json";
const ALLOWED_LAUNCHERS = new Set(["node", "bun", "npx", "bunx", "uv", "uvx", "python3", "python"]);
const PLUGIN_ID_PATTERN = /^[a-z0-9][a-z0-9._-]*$/;
const BUNDLE_ROOTS = [join(MODULE_DIR, "../plugins"), join(MODULE_DIR, "plugins")];

export type PluginInstallOptions = {
  bundleRoots?: string[];
  searchPath?: string;
};

type BundleManifest = {
  command?: string[];
  executables?: Record<string, string>;
  args?: string[];
  env?: Record<string, string>;
  shared: string[];
};

export type CatalogPlugin = {
  id: string;
  kind: string;
  name: string;
  status?: string;
  command?: string[];
  env?: Record<string, string>;
  install?: { kind: string; id?: string; package?: string };
  notes?: string;
};

export type CatalogModel = {
  id: string;
  plugin?: string;
  name?: string;
};

export type CatalogDocument = {
  version: number;
  updatedAt: string;
  models: CatalogModel[];
  plugins: CatalogPlugin[];
};

export function pluginsDirectory(home = getVoxHome()): string {
  return join(home, "plugins");
}

export function validatePluginId(id: string): void {
  if (!PLUGIN_ID_PATTERN.test(id) || id.includes("..")) {
    throw new Error(`Plugin id '${id}' is not allowed.`);
  }
}

export function pluginDirectory(id: string, home = getVoxHome()): string {
  validatePluginId(id);
  return join(pluginsDirectory(home), id);
}

export function bundledPluginPath(id: string, roots = BUNDLE_ROOTS): string | null {
  validatePluginId(id);
  for (const root of roots) {
    for (const candidate of [join(root, `${id}.mjs`), join(root, id)]) {
      if (pathInfo(candidate)) {
        requireDirectory(root);
        return candidate;
      }
    }
  }
  return null;
}

export function validatePluginCommand(command: string[]): void {
  validatePluginArguments(command);
  const launcher = command[0]!.split(/[/\\]/).pop() ?? command[0]!;
  if (!ALLOWED_LAUNCHERS.has(launcher)) {
    throw new Error(`Plugin command launcher '${launcher}' is not allowed.`);
  }
}

function validatePluginArguments(command: string[]): void {
  if (command.length === 0 || !command[0]) {
    throw new Error("Plugin command is empty.");
  }
  for (const argument of command) {
    if (/[\0\r\n;|&`$]/.test(argument) || argument.includes("$(")) {
      throw new Error(`Plugin command argument is not allowed: ${argument}`);
    }
  }
}

export async function loadCatalogDocument(): Promise<CatalogDocument> {
  const envURL = process.env.VOX_MODEL_CATALOG_URL?.trim();
  const cachePath = join(getVoxHome(), "cache", "models-catalog.json");
  const repoPath = join(MODULE_DIR, "../../../data/models.json");
  const paths = [envURL && !envURL.startsWith("http") ? envURL : null, cachePath, repoPath].filter(
    (value): value is string => Boolean(value),
  );

  for (const path of paths) {
    if (!existsSync(path)) continue;
    return parseCatalog(JSON.parse(readFileSync(path, "utf8")));
  }

  const url = envURL && envURL.startsWith("http") ? envURL : DEFAULT_CATALOG_URL;
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Model catalog request failed with HTTP ${response.status}.`);
  }
  return parseCatalog(await response.json());
}

export function parseCatalog(raw: unknown): CatalogDocument {
  const record = isRecord(raw) ? raw : {};
  const models = Array.isArray(record.models) ? record.models : [];
  const plugins = Array.isArray(record.plugins) ? record.plugins : [];
  return {
    version: Number(record.version ?? 1),
    updatedAt: String(record.updatedAt ?? ""),
    models: models.map((entry) => {
      const fields = isRecord(entry) ? entry : {};
      return {
        id: String(fields.id ?? ""),
        plugin: fields.plugin ? String(fields.plugin) : undefined,
        name: fields.name ? String(fields.name) : undefined,
      };
    }),
    plugins: plugins.map((entry) => {
      const fields = isRecord(entry) ? entry : {};
      const install = isRecord(fields.install) ? fields.install : null;
      return {
        id: String(fields.id ?? ""),
        kind: String(fields.kind ?? "asr"),
        name: String(fields.name ?? fields.id ?? ""),
        status: fields.status ? String(fields.status) : undefined,
        command: Array.isArray(fields.command) ? fields.command.map((value) => String(value)) : undefined,
        env: isRecord(fields.env)
          ? Object.fromEntries(Object.entries(fields.env).map(([key, value]) => [key, String(value)]))
          : undefined,
        install: install
          ? {
              kind: String(install.kind ?? ""),
              id: install.id ? String(install.id) : undefined,
              package: install.package ? String(install.package) : undefined,
            }
          : undefined,
        notes: fields.notes ? String(fields.notes) : undefined,
      };
    }),
  };
}

export function isPluginInstalled(id: string, home = getVoxHome()): boolean {
  return existsSync(join(pluginDirectory(id, home), "provider.json"));
}

export function installCatalogPlugin(
  plugin: CatalogPlugin,
  models: string[],
  home = getVoxHome(),
  options: PluginInstallOptions = {},
): string {
  const directory = resolve(pluginDirectory(plugin.id, home));
  const files = new Map<string, Buffer>();
  let executable: string | undefined;
  let command: string[];
  let env = plugin.env;
  const installKind = plugin.install?.kind ?? (plugin.command ? "command" : "");
  if (installKind === "bundle") {
    const bundleId = plugin.install?.id ?? plugin.id;
    const source = bundledPluginPath(bundleId, options.bundleRoots);
    if (!source) {
      throw new Error(`Bundled plugin '${bundleId}' is not shipped with this CLI.`);
    }
    const sourceInfo = pathInfo(source)!;
    if (sourceInfo.isDirectory()) {
      readBundleFiles(source, files);
      const manifestData = files.get("bundle.json");
      if (!manifestData) throw new Error(`Bundled plugin '${bundleId}' is missing bundle.json.`);
      const manifest = parseBundleManifest(JSON.parse(manifestData.toString("utf8")));
      for (const filename of manifest.shared) {
        if (files.has(filename)) throw new Error(`Shared plugin file '${filename}' conflicts with a bundle file.`);
        const sharedDirectory = join(dirname(source), "shared");
        requireDirectory(sharedDirectory);
        files.set(filename, readBundleFile(join(sharedDirectory, filename)));
      }
      if (manifest.executables) {
        const target = `${process.platform}-${process.arch}`;
        executable = manifest.executables[target];
        if (!executable) {
          throw new Error(`Bundled plugin '${bundleId}' has no executable for ${target}. Available targets: ${Object.keys(manifest.executables).join(", ")}.`);
        }
        if (!files.get(executable)?.length) {
          throw new Error(`Bundled plugin '${bundleId}' executable '${executable}' is missing or empty. Build the provider for ${target}, then retry vox plugins install.`);
        }
        command = [join(directory, executable), ...(manifest.args ?? []).map((value) => substitutePluginDirectory(value, directory))];
      } else {
        command = manifest.command!.map((value) => substitutePluginDirectory(value, directory));
      }
      env = { ...manifest.env, ...plugin.env };
    } else {
      files.set("provider.mjs", readBundleFile(source));
      command = [process.execPath, join(directory, "provider.mjs")];
    }
  } else if (installKind === "npm") {
    const npmPackage = plugin.install?.package;
    if (!npmPackage) {
      throw new Error(`Plugin '${plugin.id}' is missing install.package.`);
    }
    command = ["npx", "-y", npmPackage];
  } else if (plugin.command && plugin.command.length > 0) {
    command = plugin.command;
  } else {
    throw new Error(`Plugin '${plugin.id}' has no install method.`);
  }

  // Resolve before writing anything: Foundation.Process does not search PATH.
  if (executable) {
    // Only a shipped, validated bundle can introduce a native launcher.
    validatePluginArguments(command);
  } else {
    validatePluginCommand(command);
    command = [resolvePluginLauncher(command[0]!, options.searchPath), ...command.slice(1)];
    validatePluginCommand(command);
  }
  if (env) {
    validatePluginEnvironment(env);
    env = Object.fromEntries(Object.entries(env).map(([key, value]) => [key, substitutePluginDirectory(value, directory)]));
  }
  const provider = {
    id: plugin.id,
    kind: plugin.kind || "asr",
    command,
    models,
    env,
  };
  files.set("provider.json", Buffer.from(`${JSON.stringify(provider, null, 2)}\n`));
  installPluginFiles(directory, files, executable);
  return directory;
}

export function resolvePluginLauncher(launcher: string, searchPath = process.env.PATH ?? ""): string {
  const candidates = isAbsolute(launcher) || launcher.includes("/") || launcher.includes("\\")
    ? [resolve(launcher)]
    : searchPath.split(delimiter).map((entry) => resolve(entry || ".", launcher));
  for (const candidate of candidates) {
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Try the next PATH entry without executing the runtime.
    }
  }
  throw new Error(`Plugin runtime '${launcher}' was not found or is not executable. Install ${launcher} and add it to PATH, then retry vox plugins install.`);
}

function parseBundleManifest(raw: unknown): BundleManifest {
  if (!isRecord(raw) || (raw.command === undefined) === (raw.executables === undefined)) {
    throw new Error("Plugin bundle.json must contain exactly one of command or executables.");
  }
  if (raw.command !== undefined) {
    if (!Array.isArray(raw.command) || !raw.command.every((value) => typeof value === "string")) {
      throw new Error("Plugin bundle command must be an array of strings.");
    }
    validatePluginCommand(raw.command);
    if (raw.args !== undefined) throw new Error("Plugin bundle args require executables; command already includes arguments.");
  } else {
    if (!isRecord(raw.executables) || Object.keys(raw.executables).length === 0) {
      throw new Error("Plugin bundle executables must map platform-architecture targets to relative paths.");
    }
    for (const [target, path] of Object.entries(raw.executables)) {
      if (!/^[a-z0-9]+-[a-z0-9_]+$/.test(target) || typeof path !== "string"
          || path.includes("\\") || path.split("/").some((part) => !part || part === "." || part === "..")
          || isAbsolute(path) || /^[a-zA-Z]:/.test(path) || path === "provider.json" || path === "bundle.json") {
        throw new Error("Plugin bundle executable paths must be relative files without traversal.");
      }
      validatePluginArguments([path]);
    }
    if (raw.args !== undefined && (!Array.isArray(raw.args) || !raw.args.every((value) => typeof value === "string"))) {
      throw new Error("Plugin bundle args must be an array of strings.");
    }
    validatePluginArguments(["bundle-executable", ...(raw.args as string[] | undefined ?? [])]);
  }
  if (raw.env !== undefined) validatePluginEnvironment(raw.env);
  const shared = raw.shared ?? [];
  if (!Array.isArray(shared) || !shared.every((value) =>
    typeof value === "string" && /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(value) && !value.includes("..") && value !== "provider.json",
  )) {
    throw new Error("Plugin shared files must be plain filenames without traversal or provider.json.");
  }
  if (new Set(shared).size !== shared.length) throw new Error("Plugin shared filenames must be unique.");
  return {
    command: raw.command as string[] | undefined,
    executables: raw.executables as Record<string, string> | undefined,
    args: raw.args as string[] | undefined,
    env: raw.env as Record<string, string> | undefined, shared,
  };
}

function validatePluginEnvironment(value: unknown): asserts value is Record<string, string> {
  if (!isRecord(value) || !Object.entries(value).every(([key, entry]) =>
    /^[a-zA-Z_][a-zA-Z0-9_]*$/.test(key) && typeof entry === "string" && !entry.includes("\0"),
  )) {
    throw new Error("Plugin env must contain valid environment names and string values.");
  }
}

function substitutePluginDirectory(value: string, directory: string): string {
  const pieces = value.split("{pluginDir}");
  for (const suffix of pieces.slice(1)) {
    if ((suffix && !suffix.startsWith("/")) || /[\\/]\.\.(?:[\\/]|$)/.test(suffix) || suffix.includes("\\")) {
      throw new Error(`Plugin directory substitution must stay inside the plugin directory: ${value}`);
    }
  }
  return pieces.join(directory);
}

function pathInfo(path: string) {
  try {
    return lstatSync(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

function requireDirectory(path: string): void {
  const info = pathInfo(path);
  if (!info?.isDirectory() || info.isSymbolicLink()) throw new Error(`Plugin directory must be a real directory, not a symlink: ${path}`);
}

function readBundleFile(path: string): Buffer {
  const info = pathInfo(path);
  if (!info?.isFile() || info.isSymbolicLink()) throw new Error(`Plugin bundle file must be a regular file, not a symlink: ${path}`);
  return readFileSync(path);
}

function readBundleFiles(directory: string, files: Map<string, Buffer>, relative = ""): void {
  requireDirectory(directory);
  for (const filename of readdirSync(directory)) {
    if (filename === "__pycache__" || filename.endsWith(".pyc")) continue;
    const name = relative ? `${relative}/${filename}` : filename;
    if (name === "provider.json") throw new Error("Plugin bundle cannot contain reserved provider.json.");
    const source = join(directory, filename);
    if (pathInfo(source)?.isDirectory()) {
      readBundleFiles(source, files, name);
    } else {
      files.set(name, readBundleFile(source));
    }
  }
}

function installPluginFiles(directory: string, files: Map<string, Buffer>, executable?: string): void {
  const root = dirname(directory);
  if (pathInfo(root)) requireDirectory(root);
  if (pathInfo(directory)) requireDirectory(directory);
  mkdirSync(root, { recursive: true });
  const staging = mkdtempSync(join(root, ".plugin-install-"));
  let backup: string | undefined;
  try {
    for (const [name, data] of files) {
      const destination = join(staging, name);
      mkdirSync(dirname(destination), { recursive: true });
      writeFileSync(destination, data);
      if (name === executable) chmodSync(destination, 0o755);
    }
    if (pathInfo(directory)) {
      requireDirectory(directory);
      backup = join(root, `.plugin-backup-${randomUUID()}`);
      renameSync(directory, backup);
    }
    try {
      renameSync(staging, directory);
    } catch (error) {
      if (backup) renameSync(backup, directory);
      throw error;
    }
    if (backup) rmSync(backup, { recursive: true, force: true });
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

export function removeInstalledPlugin(id: string, home = getVoxHome()): void {
  rmSync(pluginDirectory(id, home), { recursive: true, force: true });
}

export async function handlePlugins(subcommand: string | undefined, rest: string[]): Promise<void> {
  switch (subcommand) {
    case "list":
    case undefined: {
      const catalog = await loadCatalogDocument();
      if (catalog.plugins.length === 0) {
        console.log("No plugins in the model catalog.");
        return;
      }
      for (const plugin of catalog.plugins) {
        const models = catalog.models.filter((model) => model.plugin === plugin.id).map((model) => model.id);
        const state = isPluginInstalled(plugin.id) ? "installed" : "available";
        console.log(`${plugin.id} ${plugin.kind} ${state} ${plugin.install?.kind ?? "command"}`);
        if (models.length > 0) {
          console.log(`  models: ${models.join(", ")}`);
        }
        if (plugin.notes) {
          console.log(`  ${plugin.notes}`);
        }
      }
      return;
    }
    case "install": {
      const id = rest[0];
      if (!id) {
        throw new Error("Usage: vox plugins install <id>");
      }
      const catalog = await loadCatalogDocument();
      const plugin = catalog.plugins.find((entry) => entry.id === id);
      if (!plugin) {
        throw new Error(`Unknown catalog plugin: ${id}`);
      }
      const models = catalog.models.filter((model) => model.plugin === plugin.id).map((model) => model.id);
      const directory = installCatalogPlugin(plugin, models);
      console.log(`Installed plugin ${plugin.id} at ${directory}`);
      console.log("Restart voxd to load it.");
      return;
    }
    case "remove": {
      const id = rest[0];
      if (!id) {
        throw new Error("Usage: vox plugins remove <id>");
      }
      removeInstalledPlugin(id);
      console.log(`Removed plugin ${id}`);
      console.log("Restart voxd to drop it.");
      return;
    }
    default:
      throw new Error(`Unknown plugins command: ${subcommand}`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
