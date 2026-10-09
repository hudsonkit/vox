import type { Metadata } from "next";
import Link from "next/link";
import { ArrowUpRight, AudioLines, Globe, Radar, ShieldCheck, TerminalSquare } from "lucide-react";
import { CopyCommand, CopyCommandBlock } from "../../components/copy-command";

export const metadata: Metadata = {
  title: "Web SDK · Vox",
  description: "Add local transcription to any web app with @voxd/client and Vox Companion.",
  openGraph: {
    title: "Web SDK · Vox",
    description: "Add local transcription to any web app with @voxd/client and Vox Companion.",
    images: [{ url: "/og/web.png" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Web SDK · Vox",
    description: "Add local transcription to any web app with @voxd/client and Vox Companion.",
    images: ["/og/web.png"],
  },
};

const featureCards = [
  {
    icon: Globe,
    title: "Browser-native API",
    body: "Send audio from the browser as a Blob, File, or ArrayBuffer. When Vox Companion is installed, you do not need a backend proxy.",
  },
  {
    icon: Radar,
    title: "Check first",
    body: "Call probe() when your page loads. If Vox Companion is unavailable, show a clear way to install or open it.",
  },
  {
    icon: AudioLines,
    title: "Transcribe or align",
    body: "Use transcribe() for audio already in the browser. Use align() when Vox should download audio and return word timings.",
  },
  {
    icon: ShieldCheck,
    title: "Private by default",
    body: "Vox Companion processes audio on the user's Mac. This works well for internal tools and other privacy-sensitive apps.",
  },
];

const sdkSteps = [
  ["npm install @voxd/client", "Add the browser SDK to your web app."],
  ["const client = createVoxdClient()", "Create the local bridge client."],
  ["await client.probe()", "Check whether the companion is available on this Mac."],
  ["await client.transcribe({ audio: blob })", "Send captured audio to the local runtime and get transcript text plus timing data."],
];

export default function WebSdkPage() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      <header className="sticky top-0 z-50 border-b border-line bg-canvas/92 px-6 backdrop-blur-xl sm:px-8 lg:px-12">
        <div className="mx-auto flex max-w-6xl items-center justify-between py-3">
          <div className="flex items-center gap-3 font-mono text-[12px] uppercase tracking-[0.14em]">
            <Link href="/" className="flex items-center gap-2 text-ink">
              <img src="/logo.svg" alt="Vox" className="h-5 w-5" />
              Vox
            </Link>
            <span className="text-muted">/</span>
            <span className="text-muted">Web SDK</span>
          </div>

          <div className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
            <Link href="/docs/web-integration" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Docs
            </Link>
            <Link href="/models" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Models
            </Link>
            <Link href="/download" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Download
            </Link>
            <Link href="/minivox" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Minivox
            </Link>
            <Link href="/blog" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Blog
            </Link>
            <Link href="https://github.com/hudsonkit/vox/tree/main/packages/web-client" target="_blank" rel="noreferrer noopener" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Source
            </Link>
          </div>
        </div>
      </header>

      <section className="relative overflow-hidden border-b border-line px-6 pb-20 pt-16 sm:px-8 lg:px-12">
        <div className="mx-auto max-w-6xl">
          <div className="grid gap-12 py-12 lg:grid-cols-[1.05fr_0.95fr] lg:items-start">
            <div>
              <p className="font-mono text-[11px] uppercase tracking-[0.16em] text-accent">Web SDK</p>
              <h1 className="mt-5 max-w-[16ch] text-[clamp(2.4rem,5vw,4.5rem)] font-medium leading-[1.02] tracking-[-0.045em]">
                Local transcription for web apps.
              </h1>
              <p className="mt-8 max-w-2xl text-base leading-8 text-secondary sm:text-lg">
                <code className="rounded bg-wave px-2 py-1 font-mono text-[0.95em] text-accent">@voxd/client</code> connects your web app to Vox Companion on the user&apos;s Mac. Check whether it is available, transcribe audio, add word timings, and show a clear fallback when it is offline.
              </p>

              <div className="mt-10 flex flex-col items-start gap-4 sm:flex-row sm:items-center">
                <CopyCommand command="npm install @voxd/client" />
                <Link
                  href="/docs/web-integration"
                  className="group inline-flex h-11 items-center gap-2 rounded-[3px_8px_8px_3px] border border-line-strong px-5 font-mono text-[12px] uppercase tracking-[0.1em] text-secondary transition-all hover:border-accent/50 hover:bg-wave hover:text-ink"
                >
                  Read integration docs
                  <ArrowUpRight className="h-3.5 w-3.5 opacity-40 transition-all group-hover:opacity-70 group-hover:-translate-y-px group-hover:translate-x-px" />
                </Link>
              </div>
            </div>

            <div className="signal-panel rounded-sm border border-line-strong bg-panel p-5">
              <div className="flex items-center justify-between">
                <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">SDK flow</span>
                <TerminalSquare className="h-4 w-4 text-accent" />
              </div>
              <div className="mt-4 rounded-sm border border-line bg-canvas p-4 font-mono text-[12px] leading-6 text-secondary">
                <div className="text-muted">import {"{ createVoxdClient }"} from &quot;@voxd/client&quot;</div>
                <div className="mt-3 text-ink">const client = createVoxdClient()</div>
                <div className="text-ink">if (await client.probe()) {"{"}</div>
                <div className="pl-4 text-ink">await client.transcribe({"{"} audio: blob {"}"})</div>
                <div className="text-ink">{"}"}</div>
              </div>
              <div className="mt-5 flex flex-wrap gap-2">
                {["probe()", "transcribe()", "align()", "launch()"].map((item) => (
                  <span
                    key={item}
                    className="rounded-md border border-line bg-wave px-3 py-1 font-mono text-[10px] uppercase tracking-[0.14em] text-muted"
                  >
                    {item}
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="border-y border-line bg-panel px-6 py-20 sm:px-8 lg:px-12">
        <div className="mx-auto max-w-6xl">
          <div className="mb-14">
            <h2 className="max-w-[24ch] text-3xl font-semibold leading-tight tracking-[-0.03em] sm:text-4xl">
              Connect the browser to a local speech engine.
            </h2>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            {featureCards.map(({ icon: Icon, title, body }) => (
              <article key={title} className="rounded-sm border border-line bg-canvas px-5 py-6 transition-colors hover:border-line-strong">
                <Icon className="h-5 w-5 text-accent" strokeWidth={1.7} />
                <h3 className="mt-4 text-lg font-semibold tracking-tight">{title}</h3>
                <p className="mt-3 text-sm leading-7 text-secondary">{body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="px-6 py-20 sm:px-8 lg:px-12">
        <div className="mx-auto max-w-6xl">
          <div className="grid gap-12 lg:grid-cols-[0.88fr_1.12fr]">
            <div>
              <p className="font-mono text-[11px] uppercase tracking-[0.16em] text-accent">How it works</p>
              <h2 className="mt-4 max-w-[20ch] text-3xl font-semibold leading-tight tracking-[-0.03em] sm:text-4xl">
                Install the package. Check for Vox Companion. Send audio.
              </h2>
              <p className="mt-6 max-w-md text-[15px] leading-7 text-secondary">
                The package only handles the connection to Vox. Your app still controls recording and browser permissions.
              </p>
            </div>

            <div className="space-y-3">
              {sdkSteps.map(([command, label]) => (
                <CopyCommandBlock key={command} command={command} label={label} />
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="border-t border-line bg-panel px-6 py-20 sm:px-8 lg:px-12">
        <div className="mx-auto grid max-w-6xl gap-12 lg:grid-cols-[1.05fr_0.95fr]">
          <div className="rounded-sm border border-line-strong bg-canvas p-6">
            <p className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">What the SDK does</p>
            <h2 className="mt-4 max-w-[20ch] text-3xl font-semibold leading-tight tracking-[-0.03em] sm:text-4xl">
              A small, predictable bridge to Vox Companion.
            </h2>
            <div className="mt-6 grid gap-5 text-[15px] leading-7 text-secondary">
              <p>Call <code className="rounded bg-wave px-2 py-1 font-mono text-[0.95em] text-accent">probe()</code> so your app knows whether Vox Companion is available. If it is not, show a clear install or launch option.</p>
              <p>Use <code className="rounded bg-wave px-2 py-1 font-mono text-[0.95em] text-accent">transcribe()</code> for audio already in the browser. Use <code className="rounded bg-wave px-2 py-1 font-mono text-[0.95em] text-accent">align()</code> when Vox should download the audio and return word timings.</p>
              <p>Audio stays on the Mac. Your web app gets a small, typed client instead of another speech backend.</p>
            </div>
          </div>

          <div className="rounded-sm border border-line-strong bg-canvas p-6">
            <p className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">Next stops</p>
            <div className="mt-6 grid gap-4">
              <Link
                href="/docs/web-integration"
                className="group rounded-lg border border-line bg-panel px-5 py-4 transition-all hover:border-accent/50 hover:bg-wave"
              >
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">Guide</span>
                  <ArrowUpRight className="h-3.5 w-3.5 text-muted transition-all group-hover:text-accent group-hover:-translate-y-px group-hover:translate-x-px" />
                </div>
                <p className="mt-2 text-[15px] leading-7 text-secondary">Follow the full setup guide for installation and availability checks.</p>
              </Link>

              <Link
                href="https://github.com/hudsonkit/vox/tree/main/packages/web-client"
                target="_blank"
                rel="noreferrer noopener"
                className="group rounded-lg border border-line bg-panel px-5 py-4 transition-all hover:border-accent/50 hover:bg-wave"
              >
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">Package</span>
                  <ArrowUpRight className="h-3.5 w-3.5 text-muted transition-all group-hover:text-accent group-hover:-translate-y-px group-hover:translate-x-px" />
                </div>
                <p className="mt-2 text-[15px] leading-7 text-secondary">Browse the browser client source and its current API.</p>
              </Link>

              <Link
                href="/download"
                className="group rounded-lg border border-line bg-panel px-5 py-4 transition-all hover:border-accent/50 hover:bg-wave"
              >
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">Companion</span>
                  <ArrowUpRight className="h-3.5 w-3.5 text-muted transition-all group-hover:text-accent group-hover:-translate-y-px group-hover:translate-x-px" />
                </div>
                <p className="mt-2 text-[15px] leading-7 text-secondary">Download the Mac app that connects the browser SDK to Vox.</p>
              </Link>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
