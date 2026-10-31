import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { RuntimeDiscovery } from "../src/discovery.ts";

describe("RuntimeDiscovery", () => {
  it("reads runtime info from VOX_RUNTIME_PATH", () => {
    const dir = mkdtempSync(join(tmpdir(), "vox-discovery-"));
    const runtimePath = join(dir, "runtime.json");
    process.env.VOX_RUNTIME_PATH = runtimePath;
    writeFileSync(runtimePath, JSON.stringify({
      version: "0.1.0",
      serviceName: "Vox",
      port: 43123,
      pid: 42,
      startedAt: new Date().toISOString(),
    }));

    const discovery = new RuntimeDiscovery();
    expect(discovery.read()?.port).toBe(43123);

    delete process.env.VOX_RUNTIME_PATH;
    rmSync(dir, { recursive: true, force: true });
  });
  it("refuses private capabilities without returning credentials or falling back to TCP", () => {
    const dir = mkdtempSync(join(tmpdir(), "vox-private-discovery-"));
    const runtimePath = join(dir, "runtime.json");
    const previous = process.env.VOX_RUNTIME_PATH;
    process.env.VOX_RUNTIME_PATH = runtimePath;
    try {
      writeFileSync(runtimePath, JSON.stringify({ version: "test", serviceName: "Vox", port: 0,
        pid: 42, socketPath: join(dir, "vox.sock"), transport: "unix+ws+json-rpc", authToken: "never-log-this" }));
      const discovery = new RuntimeDiscovery();
      expect(() => discovery.read()).toThrow("Private Vox runtime discovered");
      expect(() => discovery.resolvePort()).toThrow("Private Vox runtime discovered");
      expect(() => discovery.requireRuntime()).toThrow("Private Vox runtime discovered");
      try { discovery.read(); } catch (error) {
        expect(String(error)).not.toContain("never-log-this");
      }
    } finally {
      if (previous === undefined) delete process.env.VOX_RUNTIME_PATH;
      else process.env.VOX_RUNTIME_PATH = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });

});
