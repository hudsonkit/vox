import { existsSync, lstatSync, mkdirSync, mkdtempSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { dirname, join, resolve } from "path";
import {
  isEntrypoint,
  installMinivoxCommand,
  minivoxPostInstallInstructions,
  minivoxReleaseDownloadURL,
  minivoxSupportsMacOSVersion,
  parseMinivoxInstallOptions,
  removeMinivoxCommand,
  resolveMinivoxCommandDirectory,
  validateMinivoxCommandDestination,
} from "../src/index.ts";

describe("runtime fixture", () => {
  it("can create a temporary runtime file for CLI tests", () => {
    const dir = mkdtempSync(join(tmpdir(), "vox-cli-"));
    const file = join(dir, "runtime.json");
    writeFileSync(file, JSON.stringify({ port: 42137, pid: 1, serviceName: "Vox", version: "0.1.0", startedAt: new Date().toISOString() }));
    expect(existsSync(file)).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("Minivox installer", () => {
  it("runs when npm invokes the CLI through a bin symlink", () => {
    const dir = mkdtempSync(join(tmpdir(), "vox-cli-entrypoint-"));
    const modulePath = join(dir, "index.js");
    const binPath = join(dir, "vox");
    writeFileSync(modulePath, "");
    symlinkSync(modulePath, binPath);

    expect(isEntrypoint(binPath, modulePath)).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  it("requires macOS 26 or newer", () => {
    expect(minivoxSupportsMacOSVersion("26.0")).toBe(true);
    expect(minivoxSupportsMacOSVersion("27.0.1\n")).toBe(true);
    expect(minivoxSupportsMacOSVersion("15.6")).toBe(false);
    expect(minivoxSupportsMacOSVersion("")).toBe(false);
  });

  it("downloads the release matching the CLI version", () => {
    expect(minivoxReleaseDownloadURL("0.4.0")).toBe(
      "https://github.com/arach/vox/releases/download/v0.4.0/Minivox.dmg",
    );
  });

  it("accepts the documented install options", () => {
    expect(parseMinivoxInstallOptions(["--user", "--no-launch"])).toEqual({
      user: true,
      launch: false,
      verbosity: "normal",
    });
  });

  it("supports quiet and verbose installer output", () => {
    expect(parseMinivoxInstallOptions(["--quiet"]).verbosity).toBe("quiet");
    expect(parseMinivoxInstallOptions(["--verbose"]).verbosity).toBe("verbose");
    expect(() => parseMinivoxInstallOptions(["--quiet", "--verbose"])).toThrow(
      "Use either --quiet or --verbose",
    );
  });

  it("explains the first dictation after installation", () => {
    const launched = minivoxPostInstallInstructions(true).join("\n");
    expect(launched).toContain("running in your menu bar");
    expect(launched).toContain("Right ⌘M to start");
    expect(launched).toContain("Right ⌘M again to stop");
    expect(launched).toContain("minivox settings");

    expect(minivoxPostInstallInstructions(false)[0]).toContain("open Minivox");
  });

  it("installs the command in a user-owned bin directory", () => {
    expect(resolveMinivoxCommandDirectory({}, "/Users/example")).toBe("/Users/example/.local/bin");
    expect(resolveMinivoxCommandDirectory({ MINIVOX_BIN_DIR: "/custom/bin" }, "/Users/example")).toBe(
      "/custom/bin",
    );
  });

  it("links and removes the bundled Minivox command", () => {
    const dir = mkdtempSync(join(tmpdir(), "minivox-command-"));
    const app = join(dir, "Applications", "Minivox.app");
    const helper = join(app, "Contents", "MacOS", "MinivoxCommand");
    const bin = join(dir, "bin");
    mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
    writeFileSync(helper, "helper");

    const command = installMinivoxCommand(app, bin);
    expect(lstatSync(command).isSymbolicLink()).toBe(true);
    expect(resolve(dirname(command), readlinkSync(command))).toBe(helper);

    removeMinivoxCommand(app, bin);
    expect(existsSync(command)).toBe(false);
    rmSync(dir, { recursive: true, force: true });
  });

  it("does not replace an unrelated command", () => {
    const dir = mkdtempSync(join(tmpdir(), "minivox-command-conflict-"));
    const command = join(dir, "minivox");
    writeFileSync(command, "unrelated command");

    expect(() => validateMinivoxCommandDestination(dir)).toThrow(
      `Refusing to replace the existing file at ${command}`,
    );
    expect(existsSync(command)).toBe(true);
    rmSync(dir, { recursive: true, force: true });
  });

  it("rejects unknown install options", () => {
    expect(() => parseMinivoxInstallOptions(["--system"])).toThrow(
      "Unknown Minivox install option: --system",
    );
  });
});
