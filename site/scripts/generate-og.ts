import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { execFileSync } from "child_process";

const docPages = [
  { id: "overview", title: "Overview", group: "Getting Started" },
  { id: "quickstart", title: "Quickstart", group: "Getting Started" },
  { id: "web-integration", title: "Web Integration", group: "For Builders" },
  { id: "observability", title: "Observability", group: "Core" },
  { id: "architecture", title: "Architecture", group: "Core" },
  { id: "api", title: "API", group: "For Agents" },
  { id: "sdk", title: "SDK", group: "For Agents" },
  { id: "skill", title: "Operator Playbook", group: "For Agents" },
  { id: "runtime", title: "Runtime", group: "Runtime" },
  { id: "models", title: "Models", group: "Runtime" },
];

const siteRoot = process.cwd();
const publicRoot = join(siteRoot, "public");
const docsOgRoot = join(publicRoot, "og", "docs");
const tempRoot = mkdtempSync(join(tmpdir(), "vox-og-"));

function inlineFont(packagePath: string): string {
  const fontUrl = import.meta.resolve(packagePath);
  return `data:font/woff2;base64,${readFileSync(new URL(fontUrl)).toString("base64")}`;
}

const minivoxFonts = {
  monoRegular: inlineFont("@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-400-normal.woff2"),
  monoMedium: inlineFont("@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-500-normal.woff2"),
  sansRegular: inlineFont("@fontsource/space-grotesk/files/space-grotesk-latin-400-normal.woff2"),
  sansMedium: inlineFont("@fontsource/space-grotesk/files/space-grotesk-latin-500-normal.woff2"),
};

function shellEscape(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderDocTemplate(title: string, eyebrow: string, detail: string) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@500;700&display=swap" rel="stylesheet" />
    <style>
      :root {
        --bg: #09090b;
        --panel: rgba(20, 20, 22, 0.94);
        --ink: #fafafa;
        --muted: #a1a1aa;
        --soft: #71717a;
        --accent: #34d399;
        --accent-strong: #10b981;
        --line: rgba(255, 255, 255, 0.1);
        --grid: rgba(255, 255, 255, 0.045);
      }

      * { box-sizing: border-box; }

      body {
        margin: 0;
        width: 1200px;
        height: 630px;
        overflow: hidden;
        position: relative;
        background:
          radial-gradient(circle at 8% 14%, rgba(52, 211, 153, 0.14), transparent 24rem),
          radial-gradient(circle at 92% 86%, rgba(52, 211, 153, 0.08), transparent 20rem),
          var(--bg);
        color: var(--ink);
        font-family: "Inter", sans-serif;
      }

      .grid {
        position: absolute;
        inset: 0;
        background-image:
          linear-gradient(to right, var(--grid) 1px, transparent 1px),
          linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
        background-size: 48px 48px;
        opacity: 0.18;
      }

      .grid::before,
      .grid::after {
        content: "";
        position: absolute;
        inset: 0;
        background-image:
          linear-gradient(to right, var(--grid) 1px, transparent 1px),
          linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
        background-size: 48px 48px;
      }

      .grid::before {
        opacity: 0.5;
        mask-image: radial-gradient(circle at 48px 48px, black 0, black 19rem, transparent 34rem);
      }

      .grid::after {
        opacity: 0.36;
        mask-image: radial-gradient(circle at calc(100% - 48px) calc(100% - 48px), black 0, black 18rem, transparent 34rem);
      }

      .corner {
        position: absolute;
        width: 96px;
        height: 96px;
        opacity: 0.72;
      }

      .corner::before,
      .corner::after {
        content: "";
        position: absolute;
      }

      .corner::before {
        width: 96px;
        height: 2px;
        background: linear-gradient(90deg, var(--accent), transparent);
      }

      .corner::after {
        width: 2px;
        height: 96px;
        background: linear-gradient(180deg, var(--accent), transparent);
      }

      .corner.tl { top: 48px; left: 48px; }
      .corner.br { right: 48px; bottom: 48px; transform: rotate(180deg); }

      .wrap {
        position: relative;
        height: 100%;
        padding: 74px 96px 68px;
        display: flex;
        flex-direction: column;
        justify-content: space-between;
      }

      .wordmark {
        color: var(--ink);
        font-family: "JetBrains Mono", monospace;
        font-size: 38px;
        font-weight: 700;
        letter-spacing: -0.04em;
        text-transform: uppercase;
      }

      .eyebrow {
        margin-top: 40px;
        color: var(--accent);
        font-family: "JetBrains Mono", monospace;
        font-size: 16px;
        font-weight: 700;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      h1 {
        margin: 22px 0 0;
        max-width: 840px;
        font-family: "Instrument Serif", serif;
        font-size: 86px;
        line-height: 0.92;
        letter-spacing: -0.05em;
        font-weight: 400;
      }

      .detail {
        color: var(--muted);
        font-family: "JetBrains Mono", monospace;
        font-size: 20px;
        line-height: 1.7;
        letter-spacing: 0.1em;
        text-transform: uppercase;
      }

      .footer {
        display: flex;
        justify-content: space-between;
        align-items: flex-end;
        gap: 24px;
      }

      .panel {
        width: 420px;
        padding: 22px 24px 20px;
        border: 1px solid var(--line);
        border-radius: 18px;
        background: var(--panel);
        box-shadow: 0 24px 70px rgba(0, 0, 0, 0.35);
      }

      .panel-label {
        color: var(--soft);
        font-family: "JetBrains Mono", monospace;
        font-size: 14px;
        font-weight: 700;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }

      .panel-body {
        margin-top: 12px;
        color: var(--ink);
        font-family: "JetBrains Mono", monospace;
        font-size: 16px;
        font-weight: 500;
        line-height: 1.8;
      }

      .panel-accent {
        height: 4px;
        margin-top: 18px;
        border-radius: 999px;
        background: linear-gradient(90deg, transparent, var(--accent) 28%, var(--accent-strong) 72%, transparent);
      }

      .site {
        color: var(--muted);
        font-family: "JetBrains Mono", monospace;
        font-size: 18px;
        font-weight: 500;
      }
    </style>
  </head>
  <body>
    <div class="grid"></div>
    <div class="corner tl"></div>
    <div class="corner br"></div>
    <div class="wrap">
      <div>
        <div class="wordmark">Vox</div>
        <div class="eyebrow">${shellEscape(eyebrow)}</div>
        <h1>${shellEscape(title)}</h1>
      </div>
      <div class="footer">
        <div class="detail">${shellEscape(detail)}</div>
        <div class="panel">
          <div class="panel-label">Docs</div>
          <div class="panel-body">AI-ready handoff<br />Swift runtime + Node CLI + TS SDK<br />Operator-first observability</div>
          <div class="panel-accent"></div>
        </div>
      </div>
    </div>
  </body>
</html>`;
}

function renderLandingTemplate(
  title: string,
  eyebrow: string,
  detail: string,
  panelLabel = "Bridge",
  panelLines = ["npm install @voxd/client", "probe() + transcribe()", "Local companion on macOS"],
) {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=Instrument+Serif:ital@0;1&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@500;700&display=swap" rel="stylesheet" />
    <style>
      :root {
        --bg: #09090b;
        --panel: rgba(20, 20, 22, 0.94);
        --ink: #fafafa;
        --muted: #a1a1aa;
        --soft: #71717a;
        --accent: #34d399;
        --accent-strong: #10b981;
        --line: rgba(255, 255, 255, 0.1);
        --grid: rgba(255, 255, 255, 0.045);
      }

      * { box-sizing: border-box; }

      body {
        margin: 0;
        width: 1200px;
        height: 630px;
        overflow: hidden;
        position: relative;
        background:
          radial-gradient(circle at 8% 14%, rgba(52, 211, 153, 0.14), transparent 24rem),
          radial-gradient(circle at 92% 86%, rgba(52, 211, 153, 0.08), transparent 20rem),
          var(--bg);
        color: var(--ink);
        font-family: "Inter", sans-serif;
      }

      .grid {
        position: absolute;
        inset: 0;
        background-image:
          linear-gradient(to right, var(--grid) 1px, transparent 1px),
          linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
        background-size: 48px 48px;
        opacity: 0.18;
      }

      .grid::before,
      .grid::after {
        content: "";
        position: absolute;
        inset: 0;
        background-image:
          linear-gradient(to right, var(--grid) 1px, transparent 1px),
          linear-gradient(to bottom, var(--grid) 1px, transparent 1px);
        background-size: 48px 48px;
      }

      .grid::before {
        opacity: 0.5;
        mask-image: radial-gradient(circle at 48px 48px, black 0, black 19rem, transparent 34rem);
      }

      .grid::after {
        opacity: 0.36;
        mask-image: radial-gradient(circle at calc(100% - 48px) calc(100% - 48px), black 0, black 18rem, transparent 34rem);
      }

      .corner {
        position: absolute;
        width: 96px;
        height: 96px;
        opacity: 0.72;
      }

      .corner::before,
      .corner::after {
        content: "";
        position: absolute;
      }

      .corner::before {
        width: 96px;
        height: 2px;
        background: linear-gradient(90deg, var(--accent), transparent);
      }

      .corner::after {
        width: 2px;
        height: 96px;
        background: linear-gradient(180deg, var(--accent), transparent);
      }

      .corner.tl { top: 48px; left: 48px; }
      .corner.br { right: 48px; bottom: 48px; transform: rotate(180deg); }

      .wrap {
        position: relative;
        height: 100%;
        padding: 74px 96px 68px;
        display: grid;
        grid-template-columns: minmax(0, 1fr) 360px;
        column-gap: 40px;
      }

      .left {
        display: flex;
        align-items: center;
      }

      .wordmark {
        color: var(--ink);
        font-family: "JetBrains Mono", monospace;
        font-size: 38px;
        font-weight: 700;
        letter-spacing: -0.04em;
        text-transform: uppercase;
      }

      .eyebrow {
        margin-top: 34px;
        color: var(--accent);
        font-family: "JetBrains Mono", monospace;
        font-size: 16px;
        font-weight: 700;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      h1 {
        margin: 22px 0 0;
        max-width: 760px;
        font-family: "Instrument Serif", serif;
        font-size: 84px;
        line-height: 0.92;
        letter-spacing: -0.05em;
        font-weight: 400;
      }

      .detail {
        margin-top: 30px;
        color: var(--muted);
        font-family: "JetBrains Mono", monospace;
        font-size: 20px;
        line-height: 1.7;
        letter-spacing: 0.1em;
        text-transform: uppercase;
      }

      .right {
        display: flex;
        align-items: center;
        justify-content: flex-end;
      }

      .panel {
        width: 360px;
        padding: 22px 24px 20px;
        border: 1px solid var(--line);
        border-radius: 18px;
        background: var(--panel);
        box-shadow: 0 24px 70px rgba(0, 0, 0, 0.35);
      }

      .panel-label {
        color: var(--soft);
        font-family: "JetBrains Mono", monospace;
        font-size: 14px;
        font-weight: 700;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }

      .panel-body {
        margin-top: 12px;
        color: var(--ink);
        font-family: "JetBrains Mono", monospace;
        font-size: 16px;
        font-weight: 500;
        line-height: 1.8;
      }

      .panel-accent {
        height: 4px;
        margin-top: 18px;
        border-radius: 999px;
        background: linear-gradient(90deg, transparent, var(--accent) 28%, var(--accent-strong) 72%, transparent);
      }
    </style>
  </head>
  <body>
    <div class="grid"></div>
    <div class="corner tl"></div>
    <div class="corner br"></div>
    <div class="wrap">
      <div class="left">
        <div>
          <div class="wordmark">Vox</div>
          <div class="eyebrow">${shellEscape(eyebrow)}</div>
          <h1>${shellEscape(title)}</h1>
          <div class="detail">${shellEscape(detail)}</div>
        </div>
      </div>
      <div class="right">
        <div class="panel">
          <div class="panel-label">${shellEscape(panelLabel)}</div>
          <div class="panel-body">${panelLines.map(shellEscape).join("<br />")}</div>
          <div class="panel-accent"></div>
        </div>
      </div>
    </div>
  </body>
</html>`;
}

function renderMinivoxTemplate() {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <style>
      @font-face {
        font-family: "Space Grotesk";
        src: url("${minivoxFonts.sansRegular}") format("woff2");
        font-style: normal;
        font-weight: 400;
      }

      @font-face {
        font-family: "Space Grotesk";
        src: url("${minivoxFonts.sansMedium}") format("woff2");
        font-style: normal;
        font-weight: 500;
      }

      @font-face {
        font-family: "IBM Plex Mono";
        src: url("${minivoxFonts.monoRegular}") format("woff2");
        font-style: normal;
        font-weight: 400;
      }

      @font-face {
        font-family: "IBM Plex Mono";
        src: url("${minivoxFonts.monoMedium}") format("woff2");
        font-style: normal;
        font-weight: 500;
      }

      :root {
        --bg: #050505;
        --panel: #0d0d0d;
        --well: #070707;
        --ink: #f2f2f0;
        --secondary: #a0a0a0;
        --muted: #717171;
        --accent: #ef4444;
        --line: rgba(255, 255, 255, 0.1);
        --line-strong: rgba(255, 255, 255, 0.16);
      }

      * { box-sizing: border-box; }

      body {
        margin: 0;
        width: 1200px;
        height: 630px;
        overflow: hidden;
        background:
          radial-gradient(circle at 79% 48%, rgba(239, 68, 68, 0.055), transparent 19rem),
          var(--bg);
        color: var(--ink);
        font-family: "Space Grotesk", sans-serif;
      }

      .frame {
        width: 100%;
        height: 100%;
        display: grid;
        grid-template-columns: minmax(0, 1fr) 430px;
        align-items: center;
        gap: 56px;
        padding: 54px 58px;
      }

      .copy {
        align-self: stretch;
        display: flex;
        flex-direction: column;
        justify-content: center;
        min-width: 0;
      }

      .brand {
        display: flex;
        align-items: center;
        gap: 11px;
        color: var(--secondary);
        font-family: "IBM Plex Mono", monospace;
        font-size: 12px;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      .brand-mark {
        width: 8px;
        height: 8px;
        border-radius: 2px;
        background: var(--accent);
      }

      .eyebrow {
        margin-top: 64px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 13px;
        letter-spacing: 0.17em;
        text-transform: uppercase;
      }

      h1 {
        margin: 20px 0 0;
        font-size: 74px;
        font-weight: 500;
        line-height: 0.94;
        letter-spacing: -0.06em;
        white-space: nowrap;
      }

      h1 span { color: var(--accent); }

      .description {
        margin-top: 30px;
        color: var(--secondary);
        font-size: 19px;
        letter-spacing: -0.015em;
      }

      .url {
        margin-top: auto;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 11px;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }

      .preview-wrap {
        width: 430px;
      }

      .menu-bar {
        margin: 0 8px 9px 0;
        display: flex;
        align-items: center;
        justify-content: flex-end;
        gap: 9px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 10px;
        letter-spacing: 0.13em;
        text-transform: uppercase;
      }

      .menu-icon {
        display: grid;
        width: 25px;
        height: 25px;
        place-items: center;
        border: 1px solid var(--line);
        border-radius: 999px;
        color: var(--accent);
        font-size: 9px;
      }

      .app {
        overflow: hidden;
        border: 1px solid var(--line-strong);
        border-radius: 22px;
        background: var(--panel);
        box-shadow: 0 30px 90px rgba(0, 0, 0, 0.46);
      }

      .app-header {
        height: 72px;
        display: flex;
        align-items: center;
        gap: 13px;
        padding: 0 20px;
        border-bottom: 1px solid var(--line);
        background: #090909;
      }

      .app-icon {
        display: grid;
        width: 39px;
        height: 39px;
        place-items: center;
        border-radius: 12px;
        background: var(--accent);
        color: #090909;
        font-family: "IBM Plex Mono", monospace;
        font-size: 14px;
        font-weight: 500;
      }

      .app-name {
        font-size: 15px;
        font-weight: 500;
      }

      .status {
        margin-left: auto;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 6px 11px;
        border: 1px solid var(--line);
        border-radius: 999px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 9px;
        letter-spacing: 0.08em;
        text-transform: uppercase;
      }

      .status-dot {
        width: 6px;
        height: 6px;
        border-radius: 999px;
        background: var(--accent);
      }

      .app-body { padding: 20px; }

      .dictate {
        height: 204px;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        border: 1px solid var(--line);
        border-radius: 20px;
        background: var(--well);
      }

      .mic-ring {
        display: grid;
        width: 88px;
        height: 88px;
        place-items: center;
        border: 7px solid rgba(239, 68, 68, 0.72);
        border-radius: 999px;
        background: var(--panel);
        box-shadow: 0 0 48px rgba(239, 68, 68, 0.12);
      }

      .mic {
        position: relative;
        width: 14px;
        height: 23px;
        border: 2px solid var(--ink);
        border-radius: 8px;
      }

      .mic::before {
        content: "";
        position: absolute;
        left: -7px;
        top: 10px;
        width: 24px;
        height: 17px;
        border: 2px solid var(--ink);
        border-top: 0;
        border-radius: 0 0 14px 14px;
      }

      .mic::after {
        content: "";
        position: absolute;
        left: 5px;
        top: 26px;
        width: 2px;
        height: 8px;
        background: var(--ink);
        box-shadow: -5px 7px 0 0 var(--ink), 0 7px 0 0 var(--ink), 5px 7px 0 0 var(--ink);
      }

      .dictate-title {
        margin-top: 22px;
        font-size: 14px;
        font-weight: 500;
      }

      .dictate-hint {
        margin-top: 6px;
        color: var(--muted);
        font-size: 10px;
      }

      .transcript {
        margin-top: 15px;
        padding: 15px 16px 14px;
        border: 1px solid var(--line);
        border-radius: 16px;
        background: var(--well);
      }

      .transcript-top,
      .app-footer,
      .metrics {
        display: flex;
        align-items: center;
        justify-content: space-between;
        font-family: "IBM Plex Mono", monospace;
        text-transform: uppercase;
      }

      .transcript-top {
        color: var(--muted);
        font-size: 9px;
        letter-spacing: 0.12em;
      }

      .copied { color: var(--accent); }

      .transcript-text {
        margin-top: 13px;
        color: var(--secondary);
        font-size: 13px;
      }

      .metrics {
        margin-top: 14px;
        justify-content: flex-start;
        gap: 18px;
        color: #5f5f5f;
        font-size: 8px;
        letter-spacing: 0.1em;
      }

      .app-footer {
        margin-top: 16px;
        padding: 0 3px;
        color: #666;
        font-size: 8px;
        letter-spacing: 0.11em;
      }
    </style>
  </head>
  <body>
    <div class="frame">
      <div class="copy">
        <div class="brand"><span class="brand-mark"></span>Minivox / macOS</div>
        <div class="eyebrow">// open source · hackable</div>
        <h1>Smallest possible<br />dictation thing<span>.</span></h1>
        <div class="description">Tell your agents to embed it.</div>
        <div class="url">voxd.cc/minivox</div>
      </div>

      <div class="preview-wrap">
        <div class="menu-bar"><span class="menu-icon">M</span>menu bar</div>
        <div class="app">
          <div class="app-header">
            <div class="app-icon">M</div>
            <div class="app-name">Minivox</div>
            <div class="status"><span class="status-dot"></span>ready</div>
          </div>
          <div class="app-body">
            <div class="dictate">
              <div class="mic-ring"><div class="mic"></div></div>
              <div class="dictate-title">Tap to dictate</div>
              <div class="dictate-hint">Space or click.</div>
            </div>
            <div class="transcript">
              <div class="transcript-top"><span>Dictation</span><span class="copied">✓ Copied</span></div>
              <div class="transcript-text">Meet me at half past three.</div>
              <div class="metrics"><span>local</span><span>142ms</span></div>
            </div>
            <div class="app-footer"><span>Parakeet ready</span><span>Mic ready</span></div>
          </div>
        </div>
      </div>
    </div>
  </body>
</html>`;
}

function renderGithubSocialTemplate() {
  const wave = [5, 7, 6, 9, 14, 22, 28, 24, 16, 11, 9, 18, 30, 36, 28, 19, 13, 10, 8, 13, 24, 27, 18, 11, 7, 6, 9, 16, 12, 7, 5, 4, 6, 5, 4, 5, 8, 12, 9, 6];
  const bars = wave
    .map((height) => `<span class="bar${height >= 28 ? " peak" : ""}" style="height:${height}px"></span>`)
    .join("");

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <style>
      @font-face {
        font-family: "Space Grotesk";
        src: url("${minivoxFonts.sansRegular}") format("woff2");
        font-style: normal;
        font-weight: 400;
      }

      @font-face {
        font-family: "Space Grotesk";
        src: url("${minivoxFonts.sansMedium}") format("woff2");
        font-style: normal;
        font-weight: 500;
      }

      @font-face {
        font-family: "IBM Plex Mono";
        src: url("${minivoxFonts.monoRegular}") format("woff2");
        font-style: normal;
        font-weight: 400;
      }

      @font-face {
        font-family: "IBM Plex Mono";
        src: url("${minivoxFonts.monoMedium}") format("woff2");
        font-style: normal;
        font-weight: 500;
      }

      :root {
        --bg: #050505;
        --panel: #0e0e0e;
        --ink: #f0f0f0;
        --secondary: #a0a0a0;
        --muted: #787878;
        --accent: #ef4444;
        --line: rgba(255, 255, 255, 0.07);
        --line-strong: rgba(255, 255, 255, 0.12);
      }

      * { box-sizing: border-box; }

      body {
        margin: 0;
        width: 1280px;
        height: 640px;
        overflow: hidden;
        background:
          radial-gradient(circle at 78% 44%, rgba(239, 68, 68, 0.07), transparent 22rem),
          var(--bg);
        color: var(--ink);
        font-family: "Space Grotesk", sans-serif;
      }

      .frame {
        width: 100%;
        height: 100%;
        display: grid;
        grid-template-columns: minmax(0, 1fr) 488px;
        align-items: center;
        gap: 52px;
        padding: 64px 72px;
      }

      .copy {
        display: flex;
        flex-direction: column;
        justify-content: center;
        min-width: 0;
      }

      .brand {
        display: flex;
        align-items: center;
        gap: 11px;
        color: var(--secondary);
        font-family: "IBM Plex Mono", monospace;
        font-size: 13px;
        letter-spacing: 0.16em;
        text-transform: uppercase;
      }

      .brand-mark {
        width: 8px;
        height: 8px;
        border-radius: 2px;
        background: var(--accent);
      }

      .eyebrow {
        margin-top: 36px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 13px;
        letter-spacing: 0.18em;
        text-transform: uppercase;
      }

      h1 {
        margin: 16px 0 0;
        font-size: 62px;
        font-weight: 500;
        line-height: 0.94;
        letter-spacing: -0.05em;
      }

      h1 span { color: var(--accent); }

      .description {
        margin-top: 24px;
        max-width: 34ch;
        color: var(--secondary);
        font-size: 20px;
        line-height: 1.45;
        letter-spacing: -0.015em;
      }

      .wave {
        display: flex;
        align-items: flex-end;
        gap: 3px;
        height: 40px;
        margin-top: 32px;
      }

      .bar {
        width: 2px;
        border-radius: 1px;
        background: rgba(240, 240, 240, 0.22);
      }

      .bar.peak { background: var(--accent); }

      .url {
        margin-top: 40px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 12px;
        letter-spacing: 0.14em;
        text-transform: uppercase;
      }

      .window {
        overflow: hidden;
        border: 1px solid var(--line-strong);
        border-radius: 8px;
        background: var(--panel);
        box-shadow: 0 28px 80px rgba(0, 0, 0, 0.42);
      }

      .window-header {
        height: 46px;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 0 16px;
        border-bottom: 1px solid var(--line);
        background: var(--bg);
      }

      .dot {
        width: 8px;
        height: 8px;
        border-radius: 999px;
        background: rgba(255, 255, 255, 0.16);
      }

      .window-title {
        margin-left: auto;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 12px;
        letter-spacing: 0.08em;
      }

      .ready {
        display: flex;
        align-items: center;
        gap: 7px;
        margin-left: 12px;
        padding: 5px 10px;
        border: 1px solid var(--line);
        border-radius: 999px;
        color: var(--muted);
        font-family: "IBM Plex Mono", monospace;
        font-size: 10px;
        letter-spacing: 0.1em;
        text-transform: uppercase;
      }

      .ready-dot {
        width: 6px;
        height: 6px;
        border-radius: 999px;
        background: var(--accent);
      }

      .window-body {
        padding: 22px 22px 8px;
        font-family: "IBM Plex Mono", monospace;
        font-size: 15px;
        line-height: 1.7;
      }

      .cmd { color: var(--muted); }
      .out { color: var(--ink); }
      .block { margin-top: 16px; }
      .block:first-child { margin-top: 0; }

      .window-footer {
        display: flex;
        justify-content: space-between;
        margin: 8px 22px 18px;
        padding-top: 14px;
        border-top: 1px solid var(--line);
        color: #666;
        font-family: "IBM Plex Mono", monospace;
        font-size: 10px;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }
    </style>
  </head>
  <body>
    <div class="frame">
      <div class="copy">
        <div class="brand"><span class="brand-mark"></span>Vox / local-first</div>
        <div class="eyebrow">// speech runtime</div>
        <h1>macOS transcription<br />and text-to-speech<span>.</span></h1>
        <div class="description">Embed in Apple apps, or connect browsers and tools through Vox Companion.</div>
        <div class="wave">${bars}</div>
        <div class="url">github.com/arach/vox</div>
      </div>

      <div class="window">
        <div class="window-header">
          <span class="dot"></span>
          <span class="dot"></span>
          <span class="dot"></span>
          <span class="window-title">vox-operator</span>
          <span class="ready"><span class="ready-dot"></span>ready</span>
        </div>
        <div class="window-body">
          <div class="block">
            <div class="cmd">$ vox transcribe file --metrics /tmp/sample.wav</div>
            <div class="out">done · 127ms · "hello from Vox"</div>
          </div>
          <div class="block">
            <div class="cmd">$ vox models catalog</div>
            <div class="out">parakeet:v3 · gpt-transcribe · gemma-4-e2b-it</div>
          </div>
          <div class="block">
            <div class="cmd">$ vox plugins install mlx-vlm</div>
            <div class="out">plugin ready · restart voxd</div>
          </div>
        </div>
        <div class="window-footer"><span>local · measurable</span><span>apple · web · cli</span></div>
      </div>
    </div>
  </body>
</html>`;
}

function renderToPng(
  htmlPath: string,
  outputPath: string,
  size?: { width: number; height: number; scale?: number },
) {
  const args = ["x", "@arach/og", htmlPath, "-o", outputPath];
  if (size) {
    args.push("--width", String(size.width), "--height", String(size.height));
    if (size.scale != null) args.push("--scale", String(size.scale));
  }
  execFileSync("bun", args, {
    cwd: siteRoot,
    stdio: "inherit",
  });
}

function writeTempHtml(name: string, html: string) {
  const output = join(tempRoot, `${name}.html`);
  writeFileSync(output, html, "utf8");
  return output;
}

function renderMinivoxOg() {
  renderToPng(
    writeTempHtml("minivox", renderMinivoxTemplate()),
    join(publicRoot, "og", "minivox.png"),
  );
}

function renderGithubSocial() {
  const githubSize = { width: 1280, height: 640, scale: 2 };
  const siteOutput = join(publicRoot, "og", "github.png");
  const repoOutput = join(siteRoot, "..", ".github", "social-preview.png");

  mkdirSync(join(publicRoot, "og"), { recursive: true });
  mkdirSync(join(siteRoot, "..", ".github"), { recursive: true });

  renderToPng(
    writeTempHtml("github", renderGithubSocialTemplate()),
    siteOutput,
    githubSize,
  );
  copyFileSync(siteOutput, repoOutput);
}

try {
  mkdirSync(docsOgRoot, { recursive: true });

  if (process.argv.includes("--github-only")) {
    renderGithubSocial();
  } else if (process.argv.includes("--minivox-only")) {
    renderMinivoxOg();
  } else {
  renderToPng(join(siteRoot, "og-template.html"), join(publicRoot, "og.png"));
  renderToPng(
    writeTempHtml(
      "web",
      renderLandingTemplate(
        "Local transcription for web apps.",
        "Web SDK",
        "Install. Check. Transcribe locally.",
      ),
    ),
    join(publicRoot, "og", "web.png"),
  );

  renderMinivoxOg();
  renderGithubSocial();

  const docsIndexHtml = writeTempHtml(
    "docs-index",
    renderDocTemplate("Documentation for the Vox runtime.", "Docs", "Native macOS. Private. Observable."),
  );
  renderToPng(docsIndexHtml, join(publicRoot, "og", "docs.png"));

  for (const page of docPages) {
    const html = writeTempHtml(
      page.id,
      renderDocTemplate(page.title, `${page.group} / Docs`, "Swift runtime. Node CLI. TypeScript SDK."),
    );
    renderToPng(html, join(docsOgRoot, `${page.id}.png`));
  }

  // Blog index
  const blogOgRoot = join(publicRoot, "og", "blog");
  mkdirSync(blogOgRoot, { recursive: true });

  const blogIndexHtml = writeTempHtml(
    "blog-index",
    renderDocTemplate("Blog", "Vox", "Notes on building a local transcription runtime."),
  );
  renderToPng(blogIndexHtml, join(publicRoot, "og", "blog.png"));

  // Blog posts
  const blogPosts = [
    { slug: "why-vox", title: "Why I Built Vox" },
    { slug: "perf-dashboard", title: "The Performance Dashboard" },
  ];

  for (const post of blogPosts) {
    const html = writeTempHtml(
      `blog-${post.slug}`,
      renderDocTemplate(post.title, "Blog", "voxd.cc/blog"),
    );
    renderToPng(html, join(blogOgRoot, `${post.slug}.png`));
  }
  }
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}
