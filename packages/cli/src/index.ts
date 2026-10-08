#!/usr/bin/env node

import { spawn, spawnSync } from "child_process";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { writeFile } from "fs/promises";
import { homedir, tmpdir } from "os";
import { dirname, join, resolve } from "path";
import { createInterface } from "readline";
import { fileURLToPath } from "url";
import {
  getVoxHome,
  RuntimeDiscovery,
  getRuntimeFilePath,
  VoxClient,
  type DoctorReport,
  type FileTranscriptionResult,
  type ModelInfo,
  type RuntimeInfo,
  type SpeechHistoryRecord,
  type SynthesisMetrics,
  type SynthesisResult,
  type TranscriptionMetrics,
  type VoiceInfo,
  type WarmupStatus,
  type WordTiming,
  DEFAULT_PORT,
} from "@voxd/sdk";

import { handlePlugins } from "./plugins.ts";

const MODULE_DIR = dirname(fileURLToPath(import.meta.url));
const DEV_REPO_ROOT = resolve(MODULE_DIR, "../../..");
const DEV_SWIFT_ROOT = join(DEV_REPO_ROOT, "swift");
const DEV_DAEMON_BINARY = join(DEV_SWIFT_ROOT, ".build", "debug", "voxd");
const DEV_TTS_BINARY = join(DEV_SWIFT_ROOT, ".build", "debug", "voxttsd");
const CLI_VERSION = (JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as { version: string }).version;
const MINIVOX_APP_NAME = "Minivox.app";

const LAUNCH_AGENT_LABEL = "cc.voxd.daemon";
const LEGACY_LAUNCH_AGENT_LABELS = ["com.vox.daemon"];
const LAUNCH_AGENTS_DIR = join(homedir(), "Library", "LaunchAgents");
const PLIST_PATH = join(LAUNCH_AGENTS_DIR, `${LAUNCH_AGENT_LABEL}.plist`);
const LOGS_DIR = join(homedir(), ".vox", "logs");

async function main(argv: string[]): Promise<void> {
  const [command, subcommand, ...rest] = argv;

  switch (command) {
    case "daemon":
      await handleDaemon(subcommand, rest);
      return;
    case "doctor":
      await withClient(async (client) => {
        const report = await client.doctor();
        printDoctorReport(report);
      });
      return;
    case "models":
      await handleModels(subcommand, rest);
      return;
    case "warmup":
      await handleWarmup(subcommand, rest);
      return;
    case "perf":
      await handlePerf(subcommand, rest);
      return;
    case "history":
      await handleHistory(subcommand, rest);
      return;
    case "logs":
      handleLogs(subcommand, rest);
      return;
    case "transcribe":
      await handleTranscribe(subcommand, rest);
      return;
    case "speak":
      await handleSpeak(subcommand, rest);
      return;
    case "voices":
      await handleVoices(subcommand, rest);
      return;
    case "tui":
      launchTui();
      return;
    case "plugins":
      await handlePlugins(subcommand, rest);
      return;
    case "install":
      await handleInstall(subcommand, rest);
      return;
    case "uninstall":
      await handleUninstall(subcommand, rest);
      return;
    case "help":
    case undefined:
      printUsage();
      return;
    default:
      throw new Error(`Unknown command: ${command}`);
  }
}

async function handleDaemon(subcommand: string | undefined, rest: string[]): Promise<void> {
  switch (subcommand) {
    case "start":
      await ensureDaemonRunning();
      console.log("Vox daemon is running.");
      return;
    case "stop":
      await stopDaemon();
      console.log("Vox daemon stopped.");
      return;
    case "status":
      printDaemonStatus();
      return;
    default:
      throw new Error(`Unknown daemon command: ${subcommand ?? "(missing)"}`);
  }
}

async function handleModels(subcommand: string | undefined, rest: string[]): Promise<void> {
  const modelId = rest[0];

  await withClient(async (client) => {
    switch (subcommand) {
      case "list": {
        const models = await client.listModels();
        printModels(models);
        return;
      }
      case "install": {
        const model = await client.installModel(modelId, (event) => {
          console.error(`${event.modelId} ${(event.progress * 100).toFixed(0)}% ${event.status}`);
        });
        console.log(`Installed ${model.id}`);
        return;
      }
      case "preload": {
        const model = await client.preloadModel(modelId, (event) => {
          console.error(`${event.modelId} ${(event.progress * 100).toFixed(0)}% ${event.status}`);
        });
        console.log(`Preloaded ${model.id}`);
        return;
      }
      case "catalog": {
        const catalog = rest[0] === "refresh"
          ? await client.refreshCatalog()
          : await client.listCatalog();
        printCatalog(catalog);
        return;
      }
      default:
        throw new Error(`Unknown models command: ${subcommand ?? "(missing)"}`);
    }
  });
}

async function handleTranscribe(subcommand: string | undefined, rest: string[]): Promise<void> {
  switch (subcommand) {
    case "file": {
      const args = rest;
      const showMetrics = args.includes("--metrics");
      const showTimestamps = args.includes("--timestamps");
      const modelId = readOption(args, "--model");
      const filePath = readPositionalArgs(args, new Set(["--model"]))[0];
      if (!filePath) {
        throw new Error("Usage: vox transcribe file [--model <id>] [--metrics] [--timestamps] <path>");
      }
      await withClient(async (client) => {
        const result = await client.transcribeFile(resolve(process.cwd(), filePath), modelId);
        console.log(result.text);
        if (showMetrics && result.metrics) {
          printTranscriptionMetrics(result.metrics);
        }
        if (showTimestamps) {
          printWordTimings(result.words);
        }
      });
      return;
    }
    case "bench": {
      const args = rest;
      const modelId = readOption(args, "--model");
      const positional = readPositionalArgs(args, new Set(["--model"]));
      const filePath = positional[0];
      const runs = Number(positional[1] ?? 5);
      if (!filePath) {
        throw new Error("Usage: vox transcribe bench [--model <id>] <path> [runs]");
      }
      if (!Number.isInteger(runs) || runs < 1) {
        throw new Error(`Expected a positive integer run count, received: ${positional[1] ?? "(missing)"}`);
      }

      await withClient(async (client) => {
        await client.preloadModel(modelId);
        const results: FileTranscriptionResult[] = [];

        for (let index = 0; index < runs; index += 1) {
          const result = await client.transcribeFile(resolve(process.cwd(), filePath), modelId);
          results.push(result);

          const metrics = result.metrics;
          if (!metrics) {
            console.log(`run ${index + 1}: total=${result.elapsedMs}ms`);
            continue;
          }

          console.log(
            `run ${index + 1}: total=${formatMs(metrics.totalMs)} inference=${formatMs(metrics.inferenceMs)} audio=${formatMs(metrics.audioDurationMs)} rtf=${formatSpeed(metrics.realtimeFactor)}`,
          );
        }

        printBenchmarkSummary(results);
      });
      return;
    }
    case "live": {
      const args = rest;
      const showTimestamps = args.includes("--timestamps");
      const modelId = readOption(args, "--model");
      await withClient(async (client) => {
        const session = client.createLiveSession();
        session.on("state", ({ state }) => {
          console.error(`state: ${state}`);
        });
        session.on("partial", ({ text }) => {
          console.error(`partial: ${text}`);
        });
        session.on("final", ({ text, words }) => {
          console.log(text);
          if (showTimestamps) {
            printWordTimings(words);
          }
        });

        const transcriptPromise = session.start({ modelId });
        console.error("Recording. Press Enter to stop.");
        await waitForEnter();
        await session.stop();
        await transcriptPromise;
      });
      return;
    }
    case "status": {
      await withClient(async (client) => {
        printLiveSessionStatus(await client.getLiveSessionStatus());
      });
      return;
    }
    case "cancel": {
      const sessionId = rest.find((value) => !value.startsWith("--"));
      await withClient(async (client) => {
        const result = await client.cancelLiveSession(sessionId);
        console.log(`cancelled: ${result.cancelled}`);
        console.log(`session: ${result.sessionId}`);
      });
      return;
    }
    default:
      throw new Error(`Unknown transcribe command: ${subcommand ?? "(missing)"}`);
  }
}

async function handleSpeak(subcommand: string | undefined, rest: string[]): Promise<void> {
  if (subcommand === "bench") {
    const args = rest;
    const modelId = readOption(args, "--model");
    const voiceId = readOption(args, "--voice");
    const speedOption = readOption(args, "--speed");
    const speed = speedOption ? Number(speedOption) : undefined;
    const instructions = readOption(args, "--instructions");
    const positional = readPositionalArgs(args, new Set(["--model", "--voice", "--speed", "--instructions"]));
    const maybeRuns = positional.at(-1);
    const runs = maybeRuns && /^\d+$/.test(maybeRuns) ? Number(maybeRuns) : 5;
    const textParts = maybeRuns && /^\d+$/.test(maybeRuns) ? positional.slice(0, -1) : positional;
    const text = textParts.join(" ").trim();

    if (!text) {
      throw new Error("Usage: vox speak bench [--model <id>] [--voice <id>] [--speed <n>] [--instructions <text>] <text> [runs]");
    }
    if (!Number.isInteger(runs) || runs < 1) {
      throw new Error(`Expected a positive integer run count, received: ${maybeRuns ?? "(missing)"}`);
    }

    await withClient(async (client) => {
      await client.startWarmup(modelId);
      const results: SynthesisResult[] = [];

      for (let index = 0; index < runs; index += 1) {
        const result = await client.synthesize(text, { modelId, voiceId, speed, instructions, format: "wav" });
        results.push(result);

        const metrics = result.metrics;
        if (!metrics) {
          console.log(`run ${index + 1}: total=${result.elapsedMs}ms bytes=${result.audioBytes}`);
          continue;
        }

        console.log(
          `run ${index + 1}: total=${formatMs(metrics.totalMs)} synthesis=${formatMs(metrics.synthesisMs)} audio=${formatMs(metrics.audioDurationMs)} rtf=${formatSpeed(metrics.realtimeFactor)} bytes=${formatBytes(result.audioBytes)}`,
        );
      }

      printSynthesisBenchmarkSummary(results);
    });
    return;
  }

  const args = [subcommand, ...rest].filter((value): value is string => Boolean(value));
  const modelId = readOption(args, "--model");
  const voiceId = readOption(args, "--voice");
  const outputPathOption = readOption(args, "--output");
  const speedOption = readOption(args, "--speed");
  const speed = speedOption ? Number(speedOption) : undefined;
  const instructions = readOption(args, "--instructions");
  const showMetrics = args.includes("--metrics");
  const playAudio = !args.includes("--no-play");
  const text = readPositionalArgs(
    args,
    new Set(["--model", "--voice", "--output", "--speed", "--instructions", "--metrics", "--no-play"]),
  ).join(" ").trim();

  if (!text) {
    throw new Error("Usage: vox speak [--model <id>] [--voice <id>] [--output <path>] [--speed <n>] [--instructions <text>] [--metrics] [--no-play] <text>");
  }

  await withClient(async (client) => {
    const result = await client.synthesize(text, { modelId, voiceId, speed, instructions, format: "wav" });
    const outputPath = outputPathOption
      ? resolve(process.cwd(), outputPathOption)
      : makeTemporarySpeakPath(result.format);

    await writeSynthesisOutput(outputPath, result);

    if (outputPathOption) {
      console.log(`wrote: ${outputPath}`);
    } else if (playAudio && playSynthesizedAudio(outputPath)) {
      console.log(`played: ${result.voiceId || "default"} via ${result.modelId}`);
      rmSync(outputPath, { force: true });
    } else {
      console.log(`wrote: ${outputPath}`);
    }

    if (showMetrics && result.metrics) {
      printSynthesisMetrics(result.metrics);
    }
  });
}

async function handleVoices(subcommand: string | undefined, rest: string[]): Promise<void> {
  const args = subcommand === "list" || !subcommand
    ? rest
    : [subcommand, ...rest];
  const modelId = readOption(args, "--model") ?? readPositionalArgs(args, new Set(["--model"]))[0];

  await withClient(async (client) => {
    printVoices(await client.listVoices(modelId));
  });
}

async function handleWarmup(subcommand: string | undefined, rest: string[]): Promise<void> {
  const modelId = rest.find((value) => !value.startsWith("--") && Number.isNaN(Number(value)));

  await withClient(async (client) => {
    switch (subcommand) {
      case "status": {
        printWarmupStatus(await client.getWarmupStatus(modelId));
        return;
      }
      case "start": {
        printWarmupStatus(await client.startWarmup(modelId));
        return;
      }
      case "schedule": {
        const delayMs = Number(rest.find((value) => /^\d+$/.test(value)) ?? 0);
        printWarmupStatus(await client.scheduleWarmup(modelId, delayMs));
        return;
      }
      default:
        throw new Error(`Unknown warmup command: ${subcommand ?? "(missing)"}`);
    }
  });
}

async function handlePerf(subcommand: string | undefined, rest: string[]): Promise<void> {
  switch (subcommand) {
    case "dashboard":
    case undefined: {
      printPerformanceDashboard(rest);
      return;
    }
    default:
      throw new Error(`Unknown perf command: ${subcommand}`);
  }
}

async function handleHistory(subcommand: string | undefined, rest: string[]): Promise<void> {
  const command = !subcommand || subcommand.startsWith("--") ? "list" : subcommand;
  const args = subcommand?.startsWith("--") ? [subcommand, ...rest] : rest;

  switch (command) {
    case "list": {
      const limit = Number(readOption(args, "--limit") ?? 20);
      if (!Number.isInteger(limit) || limit < 1) {
        throw new Error(`Expected a positive integer limit, received: ${readOption(args, "--limit") ?? "(missing)"}`);
      }
      const clientId = readOption(args, "--client");
      const modelId = readOption(args, "--model");
      const source = readOption(args, "--source") as "file" | "live" | undefined;
      const json = args.includes("--json");
      await withClient(async (client) => {
        const result = await client.listHistory({
          kind: "transcription",
          clientId,
          modelId,
          source,
          limit,
        });
        if (json) {
          console.log(JSON.stringify(result.records, null, 2));
        } else {
          printHistoryRecords(result.records);
        }
      });
      return;
    }
    case "delete": {
      const id = rest.find((value) => !value.startsWith("--"));
      if (!id) {
        throw new Error("Usage: vox history delete <id>");
      }
      await withClient(async (client) => {
        const deleted = await client.deleteHistoryRecord(id);
        console.log(`deleted: ${deleted}`);
        console.log(`id: ${id}`);
      });
      return;
    }
    default:
      throw new Error(`Unknown history command: ${command}`);
  }
}

function handleLogs(subcommand: string | undefined, rest: string[]): void {
  const args = subcommand?.startsWith("--") ? [subcommand, ...rest] : rest;
  const tail = Number(readOption(args, "--tail") ?? 80);
  if (!Number.isInteger(tail) || tail < 1) {
    throw new Error(`Expected a positive integer tail count, received: ${readOption(args, "--tail") ?? "(missing)"}`);
  }

  const target = !subcommand || subcommand.startsWith("--") ? "daemon" : subcommand;
  const path = resolveLogPath(target);
  if (!existsSync(path)) {
    console.log(`No log at ${path}`);
    return;
  }

  console.log(`log: ${path}`);
  const content = readFileSync(path, "utf8");
  const lines = content.split("\n").filter(Boolean);
  for (const line of lines.slice(-tail)) {
    console.log(line);
  }
}

async function withClient<T>(fn: (client: VoxClient) => Promise<T>): Promise<T> {
  await ensureDaemonRunning();
  const client = new VoxClient({ clientId: "vox-cli" });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    client.disconnect();
  }
}

async function ensureDaemonRunning(): Promise<RuntimeInfo> {
  const existing = readRuntimeInfo();
  if (existing) {
    const listenerPid = findListeningPid(existing.port);
    if (listenerPid && processIsRunning(listenerPid)) {
      return listenerPid === existing.pid ? existing : { ...existing, pid: listenerPid };
    }
  }

  const voxdPath = resolveOrBuildVoxdBinary();
  const proc = spawn(voxdPath, [], {
    cwd: resolveDaemonWorkingDirectory(),
    detached: true,
    stdio: "ignore",
  });
  proc.unref();

  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const runtime = readRuntimeInfo();
    if (runtime) {
      const listenerPid = findListeningPid(runtime.port);
      if (listenerPid && processIsRunning(listenerPid)) {
        return listenerPid === runtime.pid ? runtime : { ...runtime, pid: listenerPid };
      }
    }
    await sleep(200);
  }

  throw new Error(`Timed out waiting for Vox daemon. Expected runtime file at ${getRuntimeFilePath()}`);
}

async function stopDaemon(): Promise<void> {
  const runtime = readRuntimeInfo();
  const port = runtime?.port ?? DEFAULT_PORT;
  const pids = new Set<number>();

  if (runtime && processIsRunning(runtime.pid)) {
    pids.add(runtime.pid);
  }
  const listenerPid = findListeningPid(port);
  if (listenerPid && processIsRunning(listenerPid)) {
    pids.add(listenerPid);
  }

  if (pids.size === 0) {
    rmSync(getRuntimeFilePath(), { force: true });
    return;
  }

  for (const pid of pids) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // Ignore already-exited processes.
    }
  }
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const activePid = findListeningPid(port);
    const anyRunning = [...pids].some((pid) => processIsRunning(pid));
    if (!activePid && !anyRunning) {
      rmSync(getRuntimeFilePath(), { force: true });
      return;
    }
    await sleep(100);
  }
}

function printDaemonStatus(): void {
  const runtime = readRuntimeInfo();
  const port = runtime?.port ?? DEFAULT_PORT;
  const listenerPid = findListeningPid(port);
  if (!runtime && !listenerPid) {
    console.log("Vox daemon is not running.");
    return;
  }

  const runtimeRunning = runtime ? processIsRunning(runtime.pid) : false;
  const status = listenerPid
    ? "running"
    : runtimeRunning
      ? "detached"
      : "stale";

  console.log(`status: ${status}`);
  if (listenerPid) {
    console.log(`pid: ${listenerPid}`);
  } else if (runtime) {
    console.log(`pid: ${runtime.pid}`);
  }
  console.log(`port: ${port}`);
  if (runtime && listenerPid && runtime.pid !== listenerPid) {
    console.log(`runtime pid: ${runtime.pid}`);
    console.log("warning: runtime.json does not match the process holding the port");
  }
  console.log(`runtime: ${getRuntimeFilePath()}`);
}

function printDoctorReport(report: DoctorReport): void {
  console.log(`ready: ${report.ready}`);
  for (const check of report.checks) {
    console.log(`${check.status.padEnd(7)} ${check.name} ${check.detail}`);
    if (check.remediation) {
      console.log(`        action: ${check.remediation.label} - ${check.remediation.detail}`);
    }
  }
}

function printModels(models: ModelInfo[]): void {
  for (const model of models) {
    console.log(
      `${model.id} installed=${model.installed} preloaded=${model.preloaded} available=${model.available}`,
    );
  }
}

function printCatalog(catalog: {
  version: number;
  updatedAt: string;
  models: Array<{
    id: string;
    family: string;
    name: string;
    status: string;
    default: boolean;
    vendor?: string;
    runtime?: string;
    notes?: string;
  }>;
}): void {
  console.log(`catalog v${catalog.version} updated ${catalog.updatedAt || "unknown"}`);
  for (const model of catalog.models) {
    const flags = [
      model.default ? "default" : null,
      model.status,
      model.family,
      model.runtime,
      model.vendor,
    ].filter(Boolean);
    console.log(`${model.id} ${flags.join(" ")}`);
    if (model.notes) {
      console.log(`  ${model.notes}`);
    }
  }
}

function printVoices(voices: VoiceInfo[]): void {
  if (voices.length === 0) {
    console.log("No voices available.");
    return;
  }

  for (const voice of voices) {
    const details = [
      voice.modelId,
      voice.language ? `lang=${voice.language}` : null,
      `available=${voice.available}`,
      voice.default ? "default=true" : null,
    ].filter(Boolean).join(" ");
    console.log(`${voice.id} ${voice.name} ${details}`.trim());
  }
}

function printWarmupStatus(status: WarmupStatus): void {
  console.log(`model: ${status.modelId}`);
  console.log(`state: ${status.state}`);
  if (status.requestedBy) {
    console.log(`client: ${status.requestedBy}`);
  }
  if (status.scheduledFor) {
    console.log(`scheduled: ${status.scheduledFor}`);
  }
  if (status.startedAt) {
    console.log(`started: ${status.startedAt}`);
  }
  if (status.completedAt) {
    console.log(`completed: ${status.completedAt}`);
  }
  if (status.lastError) {
    console.log(`error: ${status.lastError}`);
  }
}

function printLiveSessionStatus(status: Awaited<ReturnType<VoxClient["getLiveSessionStatus"]>>): void {
  if (!status) {
    console.log("active: no");
    return;
  }

  console.log("active: yes");
  console.log(`session: ${status.sessionId}`);
  console.log(`client: ${status.clientId}`);
  console.log(`model: ${status.modelId}`);
  console.log(`state: ${status.state}`);
  console.log(`started: ${status.startedAt}`);
}

function printHistoryRecords(records: SpeechHistoryRecord[]): void {
  if (records.length === 0) {
    console.log("No transcript history.");
    return;
  }

  for (const record of records) {
    const parts = [
      record.completedAt,
      record.source ?? record.kind,
      `client=${record.clientId}`,
      `model=${record.modelId}`,
      `elapsed=${formatMs(record.elapsedMs)}`,
      `id=${record.id}`,
    ];
    if (record.sessionId) {
      parts.splice(2, 0, `session=${record.sessionId}`);
    }
    console.log(parts.join("  "));
    if (record.text) {
      console.log(`  ${record.text}`);
    }
  }
}

interface PerformanceSample {
  timestamp: string;
  clientId: string;
  route: string;
  modelId: string;
  voiceId?: string | null;
  outcome: string;
  textLength: number;
  error?: string | null;
  metrics?: PerformanceMetrics;
}

interface PerformanceMetrics {
  traceId: string;
  audioDurationMs: number;
  wasPreloaded: boolean;
  modelCheckMs: number;
  modelLoadMs: number;
  inferenceMs: number;
  totalMs: number;
  inputBytes?: number | null;
  fileCheckMs?: number | null;
  audioLoadMs?: number | null;
  audioPrepareMs?: number | null;
  characterCount?: number | null;
  outputBytes?: number | null;
  voiceResolveMs?: number | null;
  synthesisMs?: number | null;
  realtimeFactor: number;
}

function printPerformanceDashboard(args: string[]): void {
  const clientFilter = readOption(args, "--client");
  const routeFilter = readOption(args, "--route");
  const last = Number(readOption(args, "--last") ?? 20);
  const logPath = join(getVoxHome(), "performance.jsonl");

  if (!existsSync(logPath)) {
    console.log(`No performance log at ${logPath}`);
    return;
  }

  const samples = readPerformanceSamples(logPath)
    .filter((sample) => !clientFilter || sample.clientId === clientFilter)
    .filter((sample) => !routeFilter || sample.route === routeFilter);

  if (samples.length === 0) {
    console.log("No matching performance samples.");
    return;
  }

  const successes = samples.filter((sample) => sample.outcome === "ok" && sample.metrics);
  const clients = [...new Set(samples.map((sample) => sample.clientId))].sort();
  const routes = [...new Set(samples.map((sample) => sample.route))].sort();

  console.log("Vox Performance Dashboard");
  console.log(`log: ${logPath}`);
  console.log(`samples: ${samples.length}  success: ${successes.length}  clients: ${clients.length}  routes: ${routes.join(", ")}`);
  console.log("");

  if (successes.length > 0) {
    const metrics = successes.map((sample) => sample.metrics!).filter(Boolean);
    console.log("Overall");
    console.log(`  total:     ${formatStat(computeStats(metrics.map((value) => value.totalMs)), formatMs)}`);
    console.log(`  inference: ${formatStat(computeStats(metrics.map((value) => value.inferenceMs)), formatMs)}`);
    const speedValues = metrics.map(getSpeedFactor).filter((value) => value > 0);
    if (speedValues.length > 0) {
      console.log(`  speed:     ${formatStat(computeStats(speedValues), formatSpeedFactor)}`);
    }
    console.log("");
  }

  console.log("By Client");
  console.log(`  ${pad("client", 18)} ${pad("calls", 5, true)} ${pad("p50 total", 10, true)} ${pad("p50 infer", 10, true)} ${pad("avg speed", 11, true)}`);
  for (const clientId of clients) {
    const clientSamples = successes.filter((sample) => sample.clientId === clientId).map((sample) => sample.metrics!);
    if (clientSamples.length === 0) {
      continue;
    }
    const totalStats = computeStats(clientSamples.map((value) => value.totalMs));
    const inferStats = computeStats(clientSamples.map((value) => value.inferenceMs));
    const speedStats = computeStats(clientSamples.map(getSpeedFactor).filter((value) => value > 0));
    console.log(
      `  ${pad(clientId, 18)} ${pad(String(clientSamples.length), 5, true)} ${pad(formatMs(totalStats.p50), 10, true)} ${pad(formatMs(inferStats.p50), 10, true)} ${pad(formatSpeedFactor(speedStats.avg), 11, true)}`,
    );
  }
  console.log("");

  console.log("Recent");
  for (const sample of samples.slice(-last).reverse()) {
    const stamp = sample.timestamp.replace("T", " ").replace(/\.\d+Z$/, "Z");
    if (sample.outcome !== "ok" || !sample.metrics) {
      console.log(`  ${stamp}  ${sample.clientId}  ${sample.route}  error=${sample.error ?? "unknown"}`);
      continue;
    }

    const voice = sample.voiceId ? ` voice=${sample.voiceId}` : "";
    console.log(
      `  ${stamp}  ${sample.clientId}  ${sample.route}  total=${formatMs(sample.metrics.totalMs)} infer=${formatMs(sample.metrics.inferenceMs)} audio=${formatMs(sample.metrics.audioDurationMs)} speed=${formatSpeedFactor(getSpeedFactor(sample.metrics))} model=${sample.modelId}${voice}`,
    );
  }
}

function printTranscriptionMetrics(metrics: TranscriptionMetrics): void {
  console.error(`trace: ${metrics.traceId}`);
  console.error(`audio: ${formatMs(metrics.audioDurationMs)} (${formatBytes(metrics.inputBytes)})`);
  console.error(
    `stages: file_check=${formatMs(metrics.fileCheckMs)} model_check=${formatMs(metrics.modelCheckMs)} model_load=${formatMs(metrics.modelLoadMs)} audio_load=${formatMs(metrics.audioLoadMs)} audio_prepare=${formatMs(metrics.audioPrepareMs)} inference=${formatMs(metrics.inferenceMs)}`,
  );
  console.error(`total: ${formatMs(metrics.totalMs)} (${formatSpeed(metrics.realtimeFactor)})`);
}

function printSynthesisMetrics(metrics: SynthesisMetrics): void {
  console.error(`trace: ${metrics.traceId}`);
  console.error(`audio: ${formatMs(metrics.audioDurationMs)} (${formatBytes(metrics.outputBytes)})`);
  console.error(
    `stages: model_check=${formatMs(metrics.modelCheckMs)} model_load=${formatMs(metrics.modelLoadMs)} voice_resolve=${formatMs(metrics.voiceResolveMs)} synthesis=${formatMs(metrics.synthesisMs)}`,
  );
  console.error(`total: ${formatMs(metrics.totalMs)} (${formatSpeed(metrics.realtimeFactor)})`);
}

export function formatWordTimings(words: WordTiming[]): string[] {
  if (words.length === 0) {
    return ["timestamps: unavailable"];
  }

  const startWidth = Math.max("start".length, ...words.map((word) => formatSeconds(word.start).length));
  const endWidth = Math.max("end".length, ...words.map((word) => formatSeconds(word.end).length));
  const confidenceWidth = Math.max("conf".length, ...words.map((word) => formatConfidence(word.confidence).length));
  const rows = [
    `timestamps (${words.length} words):`,
    `  ${pad("start", startWidth, true)}  ${pad("end", endWidth, true)}  ${pad("conf", confidenceWidth, true)}  word`,
  ];

  for (const word of words) {
    rows.push(
      `  ${pad(formatSeconds(word.start), startWidth, true)}  ${pad(formatSeconds(word.end), endWidth, true)}  ${pad(formatConfidence(word.confidence), confidenceWidth, true)}  ${word.word}`,
    );
  }

  return rows;
}

function printWordTimings(words: WordTiming[]): void {
  for (const line of formatWordTimings(words)) {
    console.error(line);
  }
}

function printBenchmarkSummary(results: FileTranscriptionResult[]): void {
  const metrics = results.map((result) => result.metrics).filter((value): value is TranscriptionMetrics => Boolean(value));
  if (metrics.length === 0) {
    return;
  }

  const totalStats = computeStats(metrics.map((value) => value.totalMs));
  const inferenceStats = computeStats(metrics.map((value) => value.inferenceMs));
  const speedStats = computeStats(
    metrics
      .map((value) => (value.realtimeFactor > 0 ? 1 / value.realtimeFactor : 0))
      .filter((value) => value > 0),
  );
  const audioDuration = metrics[0].audioDurationMs;

  console.log("");
  console.log(`audio duration: ${formatMs(audioDuration)}`);
  console.log(`total: ${formatStat(totalStats, formatMs)}`);
  console.log(`inference: ${formatStat(inferenceStats, formatMs)}`);
  console.log(`speed: ${formatStat(speedStats, formatSpeedFactor)}`);
}

function printSynthesisBenchmarkSummary(results: SynthesisResult[]): void {
  const metrics = results.map((result) => result.metrics).filter((value): value is SynthesisMetrics => Boolean(value));
  if (metrics.length === 0) {
    return;
  }

  const totalStats = computeStats(metrics.map((value) => value.totalMs));
  const synthesisStats = computeStats(metrics.map((value) => value.synthesisMs));
  const speedStats = computeStats(
    metrics
      .map((value) => (value.realtimeFactor > 0 ? 1 / value.realtimeFactor : 0))
      .filter((value) => value > 0),
  );
  const audioDuration = metrics[0].audioDurationMs;

  console.log("");
  console.log(`audio duration: ${formatMs(audioDuration)}`);
  console.log(`total: ${formatStat(totalStats, formatMs)}`);
  console.log(`synthesis: ${formatStat(synthesisStats, formatMs)}`);
  console.log(`speed: ${formatStat(speedStats, formatSpeedFactor)}`);
}

function computeStats(values: number[]): { avg: number; p50: number; p95: number; min: number; max: number } {
  const sorted = [...values].sort((left, right) => left - right);
  const sum = sorted.reduce((accumulator, value) => accumulator + value, 0);
  return {
    avg: sum / sorted.length,
    p50: sorted[Math.floor(sorted.length * 0.5)],
    p95: sorted[Math.floor(sorted.length * 0.95)],
    min: sorted[0],
    max: sorted[sorted.length - 1],
  };
}

function formatStat(
  stats: { avg: number; p50: number; p95: number; min: number; max: number },
  formatter: (value: number) => string,
): string {
  return `avg=${formatter(stats.avg)} p50=${formatter(stats.p50)} p95=${formatter(stats.p95)} min=${formatter(stats.min)} max=${formatter(stats.max)}`;
}

function formatMs(value: number): string {
  if (value >= 1000) {
    return `${(value / 1000).toFixed(2)}s`;
  }
  return `${Math.round(value)}ms`;
}

function formatSeconds(value: number): string {
  return `${value.toFixed(2)}s`;
}

function formatConfidence(value: number): string {
  return value > 0 ? value.toFixed(2) : "-";
}

function pad(value: string, width: number, left = false): string {
  const padding = Math.max(width - value.length, 0);
  return left ? `${" ".repeat(padding)}${value}` : `${value}${" ".repeat(padding)}`;
}

function readPerformanceSamples(logPath: string): PerformanceSample[] {
  return readFileSync(logPath, "utf8")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line) as PerformanceSample);
}

function resolveLogPath(target: string): string {
  const home = getVoxHome();
  switch (target) {
    case "daemon":
      return join(home, "logs", "voxd.log");
    case "performance":
      return join(home, "performance.jsonl");
    case "voice":
      return join(home, "voice.jsonl");
    case "history":
      return join(home, "history.jsonl");
    default:
      throw new Error(`Unknown logs target: ${target}`);
  }
}

function readOption(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  if (index === -1) {
    return undefined;
  }
  return args[index + 1];
}

function readPositionalArgs(args: string[], optionsWithValues: Set<string>): string[] {
  const values: string[] = [];

  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value.startsWith("--")) {
      if (optionsWithValues.has(value)) {
        index += 1;
      }
      continue;
    }
    values.push(value);
  }

  return values;
}

function getSpeedFactor(metrics: { realtimeFactor: number; audioDurationMs: number; inferenceMs: number }): number {
  if (metrics.realtimeFactor && Number.isFinite(metrics.realtimeFactor) && metrics.realtimeFactor > 0) {
    return 1 / metrics.realtimeFactor;
  }
  if (metrics.audioDurationMs > 0 && metrics.inferenceMs > 0) {
    return metrics.audioDurationMs / metrics.inferenceMs;
  }
  return 0;
}

function formatBytes(value: number): string {
  if (value >= 1024 * 1024) {
    return `${(value / (1024 * 1024)).toFixed(1)}MB`;
  }
  if (value >= 1024) {
    return `${(value / 1024).toFixed(0)}KB`;
  }
  return `${value}B`;
}

function formatSpeed(rtf: number): string {
  if (rtf <= 0) {
    return "n/a";
  }
  return `${(1 / rtf).toFixed(2)}x realtime`;
}

function formatSpeedFactor(value: number): string {
  return `${value.toFixed(2)}x realtime`;
}

async function writeSynthesisOutput(outputPath: string, result: SynthesisResult): Promise<void> {
  mkdirSync(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, result.audio);
}

function makeTemporarySpeakPath(format: string): string {
  const directory = join(getVoxHome(), "tmp");
  mkdirSync(directory, { recursive: true });
  return join(directory, `speak-${Date.now()}.${format}`);
}

function playSynthesizedAudio(path: string): boolean {
  const result = spawnSync("afplay", [path], { stdio: "ignore" });
  return spawnSyncStatus(result) === 0;
}

function readRuntimeInfo(): RuntimeInfo | null {
  const discovery = new RuntimeDiscovery();
  return discovery.read();
}

function processIsRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function findListeningPid(port: number): number | null {
  const result = spawnSync("lsof", [
    "-nP",
    `-iTCP:${port}`,
    "-sTCP:LISTEN",
    "-t",
  ], {
    stdio: ["ignore", "pipe", "ignore"],
  });

  if (spawnSyncStatus(result) !== 0) {
    return null;
  }

  const output = result.stdout.toString().trim().split("\n").find(Boolean);
  const pid = Number(output);
  return Number.isInteger(pid) && pid > 0 ? pid : null;
}

async function waitForEnter(): Promise<void> {
  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  await new Promise<void>((resolvePromise) => {
    rl.question("", () => {
      rl.close();
      resolvePromise();
    });
  });
}

function launchTui(): void {
  const repoRoot = resolveRepoRoot();
  if (!repoRoot) {
    throw new Error("`vox tui` is only available from a Vox repo checkout for now.");
  }
  const tuiPath = join(repoRoot, "packages", "tui", "index.tsx");
  const proc = spawnSync("bun", ["run", tuiPath], {
    cwd: repoRoot,
    stdio: "inherit",
  });
  process.exit(spawnSyncStatus(proc) ?? 1);
}

interface MinivoxInstallOptions {
  user: boolean;
  launch: boolean;
  verbosity: "quiet" | "normal" | "verbose";
}

export function minivoxReleaseDownloadURL(version = CLI_VERSION): string {
  return `https://github.com/arach/vox/releases/download/v${version}/Minivox.dmg`;
}

export const MINIVOX_MINIMUM_MACOS_MAJOR = 26;

export function minivoxSupportsMacOSVersion(productVersion: string): boolean {
  const major = Number.parseInt(productVersion.trim().split(".")[0] ?? "", 10);
  return Number.isFinite(major) && major >= MINIVOX_MINIMUM_MACOS_MAJOR;
}

export function parseMinivoxInstallOptions(args: string[]): MinivoxInstallOptions {
  const known = new Set(["--user", "--no-launch", "--quiet", "-q", "--verbose"]);
  const unknown = args.find((arg) => !known.has(arg));
  if (unknown) {
    throw new Error(`Unknown Minivox install option: ${unknown}`);
  }
  const quiet = args.includes("--quiet") || args.includes("-q");
  const verbose = args.includes("--verbose");
  if (quiet && verbose) {
    throw new Error("Use either --quiet or --verbose, not both.");
  }
  return {
    user: args.includes("--user"),
    launch: !args.includes("--no-launch"),
    verbosity: quiet ? "quiet" : verbose ? "verbose" : "normal",
  };
}

export function minivoxPostInstallInstructions(launched: boolean): string[] {
  return [
    launched
      ? "Minivox is running in your menu bar."
      : "Next, open Minivox from Applications or run `minivox`.",
    "",
    "Use Minivox:",
    "  1. Put the text cursor where you want your dictation.",
    "  2. Press Right ⌘M to start. Allow microphone and Accessibility access if asked.",
    "  3. Press Right ⌘M again to stop. Minivox copies the text and pastes it when Accessibility access is enabled.",
    "",
    "Change the shortcut or microphone: minivox settings",
  ];
}

function resolveMinivoxApplicationsDirectory(user: boolean): string {
  const override = process.env.MINIVOX_APPLICATIONS_DIR;
  if (override) return override;
  return user ? join(homedir(), "Applications") : "/Applications";
}

export function resolveMinivoxCommandDirectory(
  environment: NodeJS.ProcessEnv = process.env,
  homeDirectory = homedir(),
): string {
  return environment.MINIVOX_BIN_DIR || join(homeDirectory, ".local", "bin");
}

async function handleInstall(target: string | undefined, args: string[]): Promise<void> {
  if (target === "mini" || target === "minivox") {
    await installMinivox(parseMinivoxInstallOptions(args));
    return;
  }
  if (target) {
    throw new Error(`Unknown install target: ${target}. Use \`vox install mini\` or \`vox install\`.`);
  }

  const voxdPath = resolveVoxdBinary();
  if (!voxdPath) {
    throw new Error(
      "voxd binary not found. Install Vox.app from https://github.com/arach/vox/releases, " +
      "or place voxd at ~/.vox/bin/voxd, or build it locally with `swift build --package-path swift --product voxd`."
    );
  }

  evictLegacyLaunchAgents();
  mkdirSync(dirname(PLIST_PATH), { recursive: true });
  mkdirSync(LOGS_DIR, { recursive: true });

  writeFileSync(PLIST_PATH, buildLaunchAgentPlist(voxdPath), { mode: 0o644 });

  // Defensive: bootout any prior copy so bootstrap is idempotent.
  launchctl(["bootout", `gui/${process.getuid?.() ?? 501}/${LAUNCH_AGENT_LABEL}`], { allowFail: true });
  const code = launchctl(["bootstrap", `gui/${process.getuid?.() ?? 501}`, PLIST_PATH]);
  if (code !== 0) {
    throw new Error(`launchctl bootstrap failed with exit code ${code}. Plist written to ${PLIST_PATH}.`);
  }

  console.log("Vox Companion installed, LaunchAgent registered");
  console.log(`  plist: ${PLIST_PATH}`);
  console.log(`  voxd:  ${voxdPath}`);
  console.log(`  logs:  ${LOGS_DIR}`);
}

async function handleUninstall(target: string | undefined, args: string[]): Promise<void> {
  if (target === "mini" || target === "minivox") {
    const options = parseMinivoxInstallOptions(args);
    spawnSync("pkill", ["-x", "Minivox"], { stdio: "ignore" });
    const destination = join(resolveMinivoxApplicationsDirectory(options.user), MINIVOX_APP_NAME);
    removeMinivoxCommand(destination);
    rmSync(destination, { recursive: true, force: true });
    minivoxInstallLog(options, `Minivox removed from ${destination}`);
    return;
  }
  if (target) {
    throw new Error(`Unknown uninstall target: ${target}. Use \`vox uninstall mini\` or \`vox uninstall\`.`);
  }

  launchctl(["bootout", `gui/${process.getuid?.() ?? 501}/${LAUNCH_AGENT_LABEL}`], { allowFail: true });
  if (existsSync(PLIST_PATH)) {
    rmSync(PLIST_PATH, { force: true });
    console.log("Vox Companion uninstalled, LaunchAgent removed");
  } else {
    console.log("Vox Companion is not installed (no plist found).");
  }
  evictLegacyLaunchAgents();
}

async function installMinivox(options: MinivoxInstallOptions): Promise<void> {
  const productVersion = process.platform === "darwin"
    ? spawnSync("sw_vers", ["-productVersion"], { encoding: "utf8" }).stdout ?? ""
    : "";
  if (!minivoxSupportsMacOSVersion(productVersion)) {
    throw new Error(`Minivox requires macOS ${MINIVOX_MINIMUM_MACOS_MAJOR} or newer.`);
  }

  const applicationsDirectory = resolveMinivoxApplicationsDirectory(options.user);
  const destination = join(applicationsDirectory, MINIVOX_APP_NAME);
  validateMinivoxCommandDestination();
  const workDirectory = mkdtempSync(join(tmpdir(), "minivox-installer-"));
  const dmgPath = join(workDirectory, "Minivox.dmg");
  const mountPoint = join(workDirectory, "mounted");
  let mounted = false;

  try {
    mkdirSync(mountPoint, { recursive: true });
    const downloadURL = minivoxReleaseDownloadURL();
    minivoxInstallLog(options, `Downloading Minivox ${CLI_VERSION}…`);
    const response = await fetch(downloadURL, { redirect: "follow" });
    if (!response.ok) {
      throw new Error(`Download failed (${response.status} ${response.statusText}): ${downloadURL}`);
    }
    await writeFile(dmgPath, Buffer.from(await response.arrayBuffer()));

    minivoxInstallLog(options, "Verifying Apple notarization…");
    runMinivoxInstallerCommand("spctl", ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", dmgPath], options);
    runMinivoxInstallerCommand("hdiutil", ["attach", dmgPath, "-nobrowse", "-readonly", "-mountpoint", mountPoint], options);
    mounted = true;

    const source = join(mountPoint, MINIVOX_APP_NAME);
    if (!existsSync(source)) {
      throw new Error(`The release does not contain ${MINIVOX_APP_NAME}.`);
    }

    minivoxInstallLog(options, "Verifying the app signature…");
    runMinivoxInstallerCommand("codesign", ["--verify", "--deep", "--strict", "--verbose=2", source], options);

    mkdirSync(applicationsDirectory, { recursive: true });
    rmSync(destination, { recursive: true, force: true });
    runMinivoxInstallerCommand("ditto", [source, destination], options);
    const commandPath = installMinivoxCommand(destination);
    minivoxInstallLog(options, `Minivox installed at ${destination}`);
    minivoxInstallLog(options, `Command installed at ${commandPath}`);
    if (!commandDirectoryIsOnPath(dirname(commandPath))) {
      minivoxInstallLog(options, `Add this to your shell PATH: export PATH="${dirname(commandPath)}:$PATH"`);
    }

    if (options.launch) {
      runMinivoxInstallerCommand("open", [destination], options);
    }
    for (const line of minivoxPostInstallInstructions(options.launch)) {
      minivoxInstallLog(options, line);
    }
  } catch (error) {
    if (applicationsDirectory === "/Applications") {
      console.error("If /Applications is not writable, retry with --user.");
    }
    throw error;
  } finally {
    if (mounted) {
      const detach = spawnSync("hdiutil", ["detach", mountPoint], { stdio: "ignore" });
      if (spawnSyncStatus(detach) !== 0) {
        spawnSync("hdiutil", ["detach", "-force", mountPoint], { stdio: "ignore" });
      }
    }
    rmSync(workDirectory, { recursive: true, force: true });
  }
}

function minivoxInstallLog(options: MinivoxInstallOptions, message: string): void {
  if (options.verbosity !== "quiet") {
    console.log(message);
  }
}

function runMinivoxInstallerCommand(
  command: string,
  args: string[],
  options: MinivoxInstallOptions,
): void {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    stdio: options.verbosity === "verbose" ? "inherit" : "pipe",
  });
  if (result.error) throw result.error;
  if (spawnSyncStatus(result) !== 0) {
    const detail = typeof result.stderr === "string" ? result.stderr.trim() : "";
    throw new Error(
      `${command} exited with status ${spawnSyncStatus(result) ?? "unknown"}${detail ? `: ${detail}` : ""}`,
    );
  }
}

export function installMinivoxCommand(
  appDestination: string,
  commandDirectory = resolveMinivoxCommandDirectory(),
): string {
  const helperPath = join(appDestination, "Contents", "MacOS", "MinivoxCommand");
  if (!existsSync(helperPath)) {
    throw new Error(`The Minivox release does not contain the command helper at ${helperPath}.`);
  }

  const commandPath = validateMinivoxCommandDestination(commandDirectory);
  mkdirSync(commandDirectory, { recursive: true });
  try {
    lstatSync(commandPath);
    rmSync(commandPath);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code !== "ENOENT") throw error;
  }

  symlinkSync(helperPath, commandPath);
  return commandPath;
}

export function validateMinivoxCommandDestination(
  commandDirectory = resolveMinivoxCommandDirectory(),
): string {
  const commandPath = join(commandDirectory, "minivox");
  try {
    const existing = lstatSync(commandPath);
    if (!existing.isSymbolicLink()) {
      throw new Error(`Refusing to replace the existing file at ${commandPath}.`);
    }
    const existingTarget = resolve(dirname(commandPath), readlinkSync(commandPath));
    if (!isMinivoxCommandTarget(existingTarget)) {
      throw new Error(`Refusing to replace the existing symlink at ${commandPath}.`);
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  return commandPath;
}

export function removeMinivoxCommand(
  appDestination: string,
  commandDirectory = resolveMinivoxCommandDirectory(),
): void {
  const commandPath = join(commandDirectory, "minivox");
  try {
    const existing = lstatSync(commandPath);
    if (!existing.isSymbolicLink()) return;
    const existingTarget = resolve(dirname(commandPath), readlinkSync(commandPath));
    const expectedTarget = join(appDestination, "Contents", "MacOS", "MinivoxCommand");
    if (existingTarget === expectedTarget) {
      rmSync(commandPath);
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function commandDirectoryIsOnPath(commandDirectory: string): boolean {
  return (process.env.PATH || "").split(":").some((entry) => resolve(entry) === resolve(commandDirectory));
}

function isMinivoxCommandTarget(target: string): boolean {
  return target.endsWith(join("Minivox.app", "Contents", "MacOS", "MinivoxCommand"));
}

function runRequired(command: string, args: string[]): void {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.error) throw result.error;
  if (spawnSyncStatus(result) !== 0) {
    throw new Error(`${command} exited with status ${spawnSyncStatus(result) ?? "unknown"}`);
  }
}

function evictLegacyLaunchAgents(): void {
  for (const label of LEGACY_LAUNCH_AGENT_LABELS) {
    launchctl(["bootout", `gui/${process.getuid?.() ?? 501}/${label}`], { allowFail: true });
    rmSync(join(LAUNCH_AGENTS_DIR, `${label}.plist`), { force: true });
  }
}

function resolveVoxdBinary(): string | null {
  const candidates = [join(homedir(), ".vox", "bin", "voxd"), "/Applications/Vox.app/Contents/Resources/voxd"];
  const repoRoot = resolveRepoRoot();
  if (repoRoot) {
    const swiftRoot = join(repoRoot, "swift");
    candidates.push(
      join(swiftRoot, ".build", "release", "voxd"),
      join(swiftRoot, ".build", "debug", "voxd"),
    );
  }
  for (const path of candidates) {
    if (existsSync(path)) return path;
  }
  const which = spawnSync("/usr/bin/which", ["voxd"], {
    stdio: ["ignore", "pipe", "ignore"],
  });
  if (spawnSyncStatus(which) === 0) {
    const found = new TextDecoder().decode(which.stdout).trim();
    if (found && existsSync(found)) return found;
  }
  return null;
}

function buildLaunchAgentPlist(voxdPath: string): string {
  const stdout = join(LOGS_DIR, "voxd.stdout.log");
  const stderr = join(LOGS_DIR, "voxd.stderr.log");
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${xmlEscape(LAUNCH_AGENT_LABEL)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(voxdPath)}</string>
    <string>--port</string>
    <string>${DEFAULT_PORT}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>${xmlEscape(stdout)}</string>
  <key>StandardErrorPath</key>
  <string>${xmlEscape(stderr)}</string>
</dict>
</plist>
`;
}

function xmlEscape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function launchctl(args: string[], opts: { allowFail?: boolean } = {}): number {
  const proc = spawnSync("/bin/launchctl", args, {
    stdio: ["ignore", "ignore", opts.allowFail ? "ignore" : "inherit"],
  });
  return spawnSyncStatus(proc) ?? 1;
}

function resolveRepoRoot(): string | null {
  const swiftPackage = join(DEV_SWIFT_ROOT, "Package.swift");
  return existsSync(swiftPackage) ? DEV_REPO_ROOT : null;
}

function resolveDaemonWorkingDirectory(): string {
  return resolveRepoRoot() ?? process.cwd();
}

function resolveOrBuildVoxdBinary(): string {
  const existing = resolveVoxdBinary();
  if (existing) {
    return existing;
  }

  const repoRoot = resolveRepoRoot();
  if (!repoRoot) {
    throw new Error(
      "voxd binary not found. Install Vox.app from https://github.com/arach/vox/releases, " +
      "or place voxd at ~/.vox/bin/voxd before running CLI commands.",
    );
  }

  buildDaemon(repoRoot);
  if (existsSync(DEV_DAEMON_BINARY)) {
    return DEV_DAEMON_BINARY;
  }

  throw new Error("Failed to build voxd.");
}

function buildDaemon(repoRoot: string): void {
  if (existsSync(DEV_DAEMON_BINARY) && existsSync(DEV_TTS_BINARY)) {
    return;
  }

  const swiftRoot = join(repoRoot, "swift");
  for (const product of ["voxd", "voxttsd"]) {
    if (product === "voxd" && existsSync(DEV_DAEMON_BINARY)) {
      continue;
    }
    if (product === "voxttsd" && existsSync(DEV_TTS_BINARY)) {
      continue;
    }

    const result = spawnSync("swift", ["build", "--package-path", swiftRoot, "--product", product], {
      cwd: repoRoot,
      stdio: "inherit",
    });

    if (spawnSyncStatus(result) !== 0) {
      throw new Error(`Failed to build ${product}.`);
    }
  }
}

function spawnSyncStatus(result: { status?: number | null; exitCode?: number | null; error?: unknown }): number | null {
  if (typeof result.status === "number") {
    return result.status;
  }
  if (typeof result.exitCode === "number") {
    return result.exitCode;
  }
  return result.error ? 1 : null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolvePromise) => {
    setTimeout(resolvePromise, ms);
  });
}

export function isEntrypoint(entrypoint: string | undefined, modulePath: string): boolean {
  if (!entrypoint) {
    return false;
  }
  try {
    return realpathSync(resolve(entrypoint)) === realpathSync(modulePath);
  } catch {
    return false;
  }
}

function isMainModule(): boolean {
  return isEntrypoint(process.argv[1], fileURLToPath(import.meta.url));
}

function printUsage(): void {
  console.log(`Vox CLI

Usage:
  vox install
  vox install mini [--user] [--no-launch] [--quiet|--verbose]
  vox uninstall
  vox uninstall mini [--user] [--quiet|--verbose]
  vox daemon start|stop|status
  vox doctor
  vox models list|install|preload [modelId]
  vox models catalog [refresh]
  vox plugins list|install|remove [id]
  vox warmup status|start [modelId]
  vox warmup schedule [delayMs] [modelId]
  vox perf dashboard [--client <clientId>] [--route <route>] [--last <n>]
  vox history [list] [--client <clientId>] [--model <id>] [--source file|live] [--limit <n>] [--json]
  vox history delete <id>
  vox logs [daemon|performance|voice|history] [--tail <n>]
  vox transcribe file [--model <id>] [--metrics] [--timestamps] <path>
  vox transcribe bench [--model <id>] <path> [runs]
  vox transcribe status
  vox transcribe cancel [sessionId]
  vox transcribe live [--model <id>] [--timestamps]
  vox speak [--model <id>] [--voice <id>] [--output <path>] [--metrics] [--no-play] <text>
  vox speak bench [--model <id>] [--voice <id>] <text> [runs]
  vox voices [list] [--model <id>]
  vox tui`);
}

if (isMainModule()) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
