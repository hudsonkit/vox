import { describe, expect, it } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  installCatalogPlugin,
  isPluginInstalled,
  parseCatalog,
  removeInstalledPlugin,
  resolvePluginLauncher,
  validatePluginCommand,
  validatePluginId,
} from "../src/plugins.ts";

describe("plugin catalog", () => {
  it("parses catalog plugins and model plugin ids", () => {
    const catalog = parseCatalog({
      version: 1,
      updatedAt: "2026-08-29",
      plugins: [
        {
          id: "mlx-vlm",
          kind: "asr",
          name: "MLX-VLM",
          install: { kind: "bundle", id: "mlx-vlm" },
        },
      ],
      models: [{ id: "gemma-4-e2b-it", plugin: "mlx-vlm", name: "Gemma 4 E2B" }],
    });

    expect(catalog.plugins[0]?.id).toBe("mlx-vlm");
    expect(catalog.plugins[0]?.install?.kind).toBe("bundle");
    expect(catalog.models[0]?.plugin).toBe("mlx-vlm");
  });

  it("rejects disallowed plugin launchers", () => {
    expect(() => validatePluginCommand(["bash", "-c", "echo hi"])).toThrow("not allowed");
    expect(() => validatePluginCommand(["node", "ok.mjs"])).not.toThrow();
  });

  it("rejects plugin ids that can escape the plugins directory", () => {
    for (const id of ["../escape", "nested/plugin", "nested\\plugin", "a..b", ".hidden", "Uppercase"]) {
      expect(() => validatePluginId(id)).toThrow("not allowed");
    }
    for (const id of ["mlx-vlm", "mlx_vlm.v2", "plugin-2"]) {
      expect(() => validatePluginId(id)).not.toThrow();
    }
  });

  it("rejects traversal ids before install or removal touches the filesystem", () => {
    const home = mkdtempSync(join(tmpdir(), "vox-plugin-traversal-"));
    try {
      expect(() =>
        installCatalogPlugin(
          {
            id: "../escape",
            kind: "asr",
            name: "Escape",
            command: ["node", "provider.mjs"],
          },
          [],
          home,
        ),
      ).toThrow("not allowed");
      expect(() => removeInstalledPlugin("../escape", home)).toThrow("not allowed");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("installs the bundled mlx-vlm plugin into VOX_HOME", () => {
    const home = mkdtempSync(join(tmpdir(), "vox-plugins-"));
    try {
      const directory = installCatalogPlugin(
        {
          id: "mlx-vlm",
          kind: "asr",
          name: "MLX-VLM",
          install: { kind: "bundle", id: "mlx-vlm" },
        },
        ["gemma-4-e2b-it"],
        home,
      );
      expect(isPluginInstalled("mlx-vlm", home)).toBe(true);
      const provider = JSON.parse(readFileSync(join(directory, "provider.json"), "utf8")) as {
        id: string;
        command: string[];
        models: string[];
      };
      expect(provider.id).toBe("mlx-vlm");
      expect(provider.models).toEqual(["gemma-4-e2b-it"]);
      expect(["node", "bun"].includes(provider.command[0]?.split(/[/\\]/).pop() ?? "")).toBe(true);
      expect(provider.command[1]?.endsWith("provider.mjs")).toBe(true);
      removeInstalledPlugin("mlx-vlm", home);
      expect(isPluginInstalled("mlx-vlm", home)).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

const whistlePlugin = {
  id: "whistle",
  kind: "asr",
  name: "Whistle",
  install: { kind: "bundle", id: "whistle" },
};

function bundleFixture(manifest: unknown = {
  command: ["uv", "run", "--script", "{pluginDir}/provider.py"],
  env: { VOX_PROVIDER_CALL_TIMEOUT_SECONDS: "180", PROVIDER_ROOT: "{pluginDir}" },
  shared: ["vox_provider.py"],
}) {
  const root = mkdtempSync(join(tmpdir(), "vox-plugin-bundle-"));
  const home = join(root, "home");
  const plugins = join(root, "plugins");
  const bundle = join(plugins, "whistle");
  const runtimeDirectory = join(root, "bin");
  mkdirSync(bundle, { recursive: true });
  mkdirSync(join(plugins, "shared"));
  mkdirSync(runtimeDirectory);
  writeFileSync(join(bundle, "bundle.json"), JSON.stringify(manifest));
  writeFileSync(join(bundle, "provider.py"), "import vox_provider\n");
  writeFileSync(join(plugins, "shared", "vox_provider.py"), "PROTOCOL_VERSION = 1\n");
  // Registration must inspect this executable without running it.
  const runtime = join(runtimeDirectory, "uv");
  const marker = join(root, "runtime-was-run");
  writeFileSync(runtime, `#!/bin/sh\ntouch '${marker}'\nexit 97\n`);
  chmodSync(runtime, 0o755);
  return {
    root, home, plugins, bundle, runtimeDirectory, runtime, marker,
    options: { bundleRoots: [plugins], searchPath: runtimeDirectory },
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}

describe("directory plugin bundles", () => {
  it("installs Whistle files and shared protocol code with an absolute runtime, without executing it", () => {
    const fixture = bundleFixture();
    try {
      mkdirSync(join(fixture.bundle, "support"));
      writeFileSync(join(fixture.bundle, "support", "config.json"), "{}");
      mkdirSync(join(fixture.bundle, "__pycache__"));
      writeFileSync(join(fixture.bundle, "__pycache__", "provider.cpython-314.pyc"), "generated");
      writeFileSync(join(fixture.bundle, "support", "cache.pyc"), "generated");
      const directory = installCatalogPlugin(
        { ...whistlePlugin, env: { VOX_PROVIDER_CALL_TIMEOUT_SECONDS: "240" } },
        ["whistle-small"], fixture.home, fixture.options,
      );
      const provider = JSON.parse(readFileSync(join(directory, "provider.json"), "utf8"));
      expect(provider.command).toEqual([fixture.runtime, "run", "--script", join(directory, "provider.py")]);
      expect(provider.models).toEqual(["whistle-small"]);
      expect(provider.env).toEqual({ VOX_PROVIDER_CALL_TIMEOUT_SECONDS: "240", PROVIDER_ROOT: directory });
      expect(readFileSync(join(directory, "vox_provider.py"), "utf8")).toBe("PROTOCOL_VERSION = 1\n");
      expect(readFileSync(join(directory, "support", "config.json"), "utf8")).toBe("{}");
      expect(existsSync(join(directory, "__pycache__"))).toBe(false);
      expect(existsSync(join(directory, "support", "cache.pyc"))).toBe(false);
      expect(existsSync(fixture.marker)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("resolves PATH launchers for catalog command plugins too", () => {
    const fixture = bundleFixture();
    try {
      const directory = installCatalogPlugin(
        { id: "command-plugin", name: "Command", kind: "asr", command: ["uv", "run", "provider.py"] },
        [], fixture.home, fixture.options,
      );
      const provider = JSON.parse(readFileSync(join(directory, "provider.json"), "utf8"));
      expect(provider.command[0]).toBe(fixture.runtime);
      expect(existsSync(fixture.marker)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("skips non-executable PATH entries and reports missing runtimes before creating an installation", () => {
    const fixture = bundleFixture();
    try {
      const unavailable = join(fixture.root, "unavailable");
      mkdirSync(unavailable);
      writeFileSync(join(unavailable, "uv"), "not executable");
      expect(resolvePluginLauncher("uv", `${unavailable}:${fixture.runtimeDirectory}`)).toBe(fixture.runtime);
      expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, { ...fixture.options, searchPath: unavailable })).toThrow("Install uv and add it to PATH");
      expect(existsSync(fixture.home)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("keeps an existing installation intact if replacement command validation fails", () => {
    const fixture = bundleFixture();
    try {
      const directory = installCatalogPlugin(whistlePlugin, ["original"], fixture.home, fixture.options);
      const original = readFileSync(join(directory, "provider.json"), "utf8");
      writeFileSync(join(fixture.bundle, "provider.py"), "replacement\n");
      writeFileSync(join(fixture.bundle, "bundle.json"), JSON.stringify({ command: ["bash", "-c", "anything"] }));
      expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow("not allowed");
      expect(readFileSync(join(directory, "provider.json"), "utf8")).toBe(original);
      expect(readFileSync(join(directory, "provider.py"), "utf8")).toBe("import vox_provider\n");
    } finally {
      fixture.cleanup();
    }
  });

  it("replaces an installed bundle only after the complete replacement validates", () => {
    const fixture = bundleFixture();
    try {
      const directory = installCatalogPlugin(whistlePlugin, ["original"], fixture.home, fixture.options);
      writeFileSync(join(fixture.bundle, "provider.py"), "replacement\n");
      installCatalogPlugin(whistlePlugin, ["replacement"], fixture.home, fixture.options);
      expect(readFileSync(join(directory, "provider.py"), "utf8")).toBe("replacement\n");
      expect(JSON.parse(readFileSync(join(directory, "provider.json"), "utf8")).models).toEqual(["replacement"]);
    } finally {
      fixture.cleanup();
    }
  });

  it("rejects malformed manifests, traversal, reserved shared files, and shell syntax before mutation", () => {
    const command = ["uv", "run", "--script", "{pluginDir}/provider.py"];
    const manifests = [
      { command: "uv run provider.py" },
      { command: ["uv", 12] },
      { command: [] },
      { command, shared: ["../outside.py"] },
      { command, shared: ["nested/provider.py"] },
      { command, shared: ["nested\\provider.py"] },
      { command, shared: ["provider.json"] },
      { command, shared: ["vox_provider.py", "vox_provider.py"] },
      { command: ["uv", "run", "{pluginDir}/../outside.py"] },
      { command: ["uv", "run", "{pluginDir}outside.py"] },
      { command: ["uv", "run", "{pluginDir}/provider.py;curl evil"] },
      { command, env: { INVALID: 12 } },
      { command, env: { "INVALID=KEY": "value" } },
      { command, env: { ROOT: "{pluginDir}/../escape" } },
    ];
    for (const manifest of manifests) {
      const fixture = bundleFixture(manifest);
      try {
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow();
        expect(existsSync(fixture.home)).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });

  it("validates command restrictions again after substituting the installation path", () => {
    const fixture = bundleFixture();
    try {
      const home = join(fixture.root, "unsafe;home");
      expect(() => installCatalogPlugin(whistlePlugin, [], home, fixture.options)).toThrow("not allowed");
      expect(existsSync(home)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("rejects symlinked bundle files, shared files, and nested directories", () => {
    for (const location of ["bundle-file", "shared-file", "nested-directory", "bundle-directory"]) {
      const fixture = bundleFixture();
      try {
        const outside = join(fixture.root, "outside.py");
        writeFileSync(outside, "outside\n");
        if (location === "bundle-file") {
          rmSync(join(fixture.bundle, "provider.py"));
          symlinkSync(outside, join(fixture.bundle, "provider.py"));
        } else if (location === "shared-file") {
          rmSync(join(fixture.plugins, "shared", "vox_provider.py"));
          symlinkSync(outside, join(fixture.plugins, "shared", "vox_provider.py"));
        } else if (location === "nested-directory") {
          symlinkSync(fixture.root, join(fixture.bundle, "escape"));
        } else {
          rmSync(fixture.bundle, { recursive: true });
          symlinkSync(fixture.root, fixture.bundle);
        }
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow("symlink");
        expect(existsSync(fixture.home)).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });

  it("rejects symlinked destination directories without changing the target", () => {
    for (const symlinkPluginsRoot of [false, true]) {
      const fixture = bundleFixture();
      try {
        const outside = join(fixture.root, "outside");
        mkdirSync(outside);
        writeFileSync(join(outside, "untouched"), "original");
        mkdirSync(fixture.home);
        if (symlinkPluginsRoot) {
          symlinkSync(outside, join(fixture.home, "plugins"));
        } else {
          mkdirSync(join(fixture.home, "plugins"));
          symlinkSync(outside, join(fixture.home, "plugins", "whistle"));
        }
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow("symlink");
        expect(readFileSync(join(outside, "untouched"), "utf8")).toBe("original");
        expect(existsSync(join(outside, "provider.json"))).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });

  it("rejects shared file collisions and missing shared modules before mutation", () => {
    for (const collision of [false, true]) {
      const fixture = bundleFixture();
      try {
        if (collision) writeFileSync(join(fixture.bundle, "vox_provider.py"), "conflict\n");
        else rmSync(join(fixture.plugins, "shared", "vox_provider.py"));
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow();
        expect(existsSync(fixture.home)).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });
});

const nativeTarget = `${process.platform}-${process.arch}`;
const nativePath = `bin/${nativeTarget}/vox-whistle`;

function nativeBundleFixture() {
  const fixture = bundleFixture({
    executables: { [nativeTarget]: nativePath },
    args: ["--assets", "{pluginDir}/assets"],
  });
  const binary = join(fixture.bundle, nativePath);
  mkdirSync(join(fixture.bundle, "bin", nativeTarget), { recursive: true });
  writeFileSync(binary, "native executable fixture; never run during registration\n");
  chmodSync(binary, 0o644);
  return { ...fixture, binary };
}

describe("native executable plugin bundles", () => {
  it("selects the host executable and grants only that installed file executable permissions", () => {
    const fixture = nativeBundleFixture();
    try {
      const directory = installCatalogPlugin(whistlePlugin, ["whistle"], fixture.home, fixture.options);
      const provider = JSON.parse(readFileSync(join(directory, "provider.json"), "utf8"));
      expect(provider.command).toEqual([join(directory, nativePath), "--assets", join(directory, "assets")]);
      expect(readFileSync(join(directory, nativePath), "utf8")).toBe(readFileSync(fixture.binary, "utf8"));
      expect(statSync(join(directory, nativePath)).mode & 0o7777).toBe(0o755);
      expect(statSync(join(directory, "provider.py")).mode & 0o111).toBe(0);
      expect(statSync(fixture.binary).mode & 0o111).toBe(0);
      expect(existsSync(fixture.marker)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("rejects unsupported platforms and absent builds before touching the destination", () => {
    for (const failure of ["unsupported", "missing", "empty"]) {
      const fixture = nativeBundleFixture();
      try {
        if (failure === "unsupported") {
          writeFileSync(join(fixture.bundle, "bundle.json"), JSON.stringify({ executables: { "other-arch": nativePath } }));
        } else if (failure === "missing") rmSync(fixture.binary);
        else writeFileSync(fixture.binary, "");
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options))
          .toThrow(failure === "unsupported" ? `no executable for ${nativeTarget}` : "Build the provider");
        expect(existsSync(fixture.home)).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });

  it("preserves the installed executable and metadata when a replacement build is missing", () => {
    const fixture = nativeBundleFixture();
    try {
      const directory = installCatalogPlugin(whistlePlugin, ["original"], fixture.home, fixture.options);
      const previous = readFileSync(join(directory, "provider.json"), "utf8");
      const binary = readFileSync(join(directory, nativePath), "utf8");
      rmSync(fixture.binary);
      expect(() => installCatalogPlugin(whistlePlugin, ["replacement"], fixture.home, fixture.options)).toThrow("Build the provider");
      expect(readFileSync(join(directory, "provider.json"), "utf8")).toBe(previous);
      expect(readFileSync(join(directory, nativePath), "utf8")).toBe(binary);
      expect(statSync(join(directory, nativePath)).mode & 0o7777).toBe(0o755);
    } finally {
      fixture.cleanup();
    }
  });

  it("rejects ambiguous native manifests, path escapes, and unsafe arguments", () => {
    const executables = { [nativeTarget]: nativePath };
    const manifests = [
      { command: ["node", "provider.mjs"], executables },
      { command: ["node", "provider.mjs"], args: [] },
      { executables: {} },
      { executables: [] },
      { executables, args: "--help" },
      { executables, args: [true] },
      { executables, args: ["bad;argument"] },
      { executables, args: ["{pluginDir}/../escape"] },
      ...["/bin/native", "C:/bin/native", "../native", "bin/../native", "bin\\native", "bin//native", "./native", "provider.json", "bundle.json", "bad$native"]
        .map((path) => ({ executables: { [nativeTarget]: path } })),
      { executables: { ...executables, "other-arch": "../escape" } },
    ];
    for (const manifest of manifests) {
      const fixture = nativeBundleFixture();
      try {
        writeFileSync(join(fixture.bundle, "bundle.json"), JSON.stringify(manifest));
        expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow();
        expect(existsSync(fixture.home)).toBe(false);
      } finally {
        fixture.cleanup();
      }
    }
  });

  it("rejects native symlinks and rechecks the expanded absolute command path", () => {
    const fixture = nativeBundleFixture();
    try {
      expect(() => installCatalogPlugin(whistlePlugin, [], join(fixture.root, "unsafe;home"), fixture.options)).toThrow("not allowed");
      rmSync(fixture.binary);
      symlinkSync(fixture.runtime, fixture.binary);
      expect(() => installCatalogPlugin(whistlePlugin, [], fixture.home, fixture.options)).toThrow("symlink");
      expect(existsSync(fixture.home)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });

  it("does not authorize native executables supplied by remote catalog command entries", () => {
    const fixture = nativeBundleFixture();
    try {
      chmodSync(fixture.binary, 0o755);
      expect(() => installCatalogPlugin({
        id: "remote-native", kind: "asr", name: "Unbundled native", command: [fixture.binary],
      }, [], fixture.home, fixture.options)).toThrow("not allowed");
      expect(() => validatePluginCommand([fixture.binary])).toThrow("not allowed");
      expect(existsSync(fixture.home)).toBe(false);
    } finally {
      fixture.cleanup();
    }
  });
});
