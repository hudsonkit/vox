import { existsSync, readFileSync } from "fs";
import { DEFAULT_PORT, getRuntimeFilePath } from "./constants.ts";
import { ServiceUnavailableError } from "./errors.ts";
import type { RuntimeInfo } from "./types.ts";

export class RuntimeDiscovery {
  read(): RuntimeInfo | null {
    const runtimePath = getRuntimeFilePath();
    if (!existsSync(runtimePath)) {
      return null;
    }

    try {
      const raw = readFileSync(runtimePath, "utf8");
      const parsed = JSON.parse(raw) as RuntimeInfo & {
        socketPath?: unknown; authToken?: unknown; authTokenPath?: unknown; transport?: unknown;
      };
      if (parsed && (parsed.socketPath !== undefined || parsed.authToken !== undefined ||
          parsed.authTokenPath !== undefined || parsed.transport === "unix+ws+json-rpc")) {
        throw new ServiceUnavailableError(
          "Private Vox runtime discovered; this TCP client cannot use it. Use Swift VoxClient; no TCP fallback or second daemon was started."
        );
      }
      if (!parsed.port || !parsed.pid || !parsed.serviceName) {
        return null;
      }
      // Project metadata, never return unexpected credential fields to status/log consumers.
      return { version: parsed.version, serviceName: parsed.serviceName, port: parsed.port,
        pid: parsed.pid, startedAt: parsed.startedAt };
    } catch (error) {
      if (error instanceof ServiceUnavailableError) throw error;
      return null;
    }
  }

  resolvePort(overridePort?: number): number {
    if (overridePort) {
      return overridePort;
    }

    const runtime = this.read();
    if (runtime?.port) {
      return runtime.port;
    }

    return DEFAULT_PORT;
  }

  requireRuntime(): RuntimeInfo {
    const runtime = this.read();
    if (!runtime) {
      throw new ServiceUnavailableError(`No runtime info found at ${getRuntimeFilePath()}`);
    }
    return runtime;
  }
}
