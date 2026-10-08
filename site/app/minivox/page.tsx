import type { Metadata } from "next";
import Link from "next/link";
import {
  ArrowLeft,
  ArrowUpRight,
  Check,
  Clipboard,
  Download,
  Github,
  Mic,
  MousePointer2,
  Sparkles,
} from "lucide-react";
import { CopyCommand } from "../../components/copy-command";

export const metadata: Metadata = {
  title: "Minivox · Tiny local dictation",
  description: "Minivox is a tiny macOS menu-bar app for fast, local dictation with Vox.",
  openGraph: {
    title: "Minivox · Tiny local dictation",
    description: "Click, speak, stop. Minivox transcribes locally and copies the text.",
    images: [{ url: "/og/minivox.png" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Minivox · Tiny local dictation",
    description: "Click, speak, stop. Minivox transcribes locally and copies the text.",
    images: ["/og/minivox.png"],
  },
};

const sourceUrl = "https://github.com/arach/vox/tree/main/apps/minivox";
const downloadUrl = "https://github.com/arach/vox/releases/latest/download/Minivox.dmg";

const steps = [
  { idx: "01", icon: MousePointer2, title: "Click", body: "Open Minivox from the menu bar and tap the microphone." },
  { idx: "02", icon: Mic, title: "Speak", body: "Say what you need. Parakeet transcribes the recording locally." },
  { idx: "03", icon: Clipboard, title: "Paste", body: "The finished dictation copies itself, ready for any app." },
];

export default function MinivoxPage() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      <div className="border-b border-line bg-canvas">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-2 font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
          <span>Minivox</span>
          <span className="hidden items-center gap-2 text-secondary sm:inline-flex">
            <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-accent" />
            one small job
          </span>
          <span>local dictation</span>
        </div>
      </div>

      <header className="border-b border-line">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
          <Link href="/" className="flex items-center gap-3">
            <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-accent" />
            <span className="text-[15px] font-medium tracking-tight text-ink">Vox</span>
            <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">/ Minivox</span>
          </Link>
          <nav aria-label="Minivox" className="flex items-center gap-1 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
            <Link href="/" className="hidden px-2.5 py-1.5 transition-colors hover:text-accent sm:inline-flex">Home</Link>
            <a href={downloadUrl} className="px-2.5 py-1.5 transition-colors hover:text-accent">Download</a>
            <Link href="/models" className="px-2.5 py-1.5 transition-colors hover:text-accent">Models</Link>
            <Link href="/docs/apple-embed" className="px-2.5 py-1.5 transition-colors hover:text-accent">Embed guide</Link>
            <Link href={sourceUrl} target="_blank" rel="noreferrer noopener" className="px-2.5 py-1.5 transition-colors hover:text-accent">Source</Link>
          </nav>
        </div>
      </header>

      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl gap-14 px-6 py-20 lg:grid-cols-[1fr_0.9fr] lg:items-center">
          <div>
            <Link href="/" className="inline-flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.14em] text-muted transition-colors hover:text-accent">
              <ArrowLeft className="h-3 w-3" />
              Back to Vox
            </Link>
            <p className="mt-9 font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// tiny dictation"}</p>
            <h1 className="mt-5 max-w-[12ch] text-[clamp(2.7rem,6vw,5.2rem)] font-medium leading-[0.98] tracking-[-0.05em] text-ink">
              Say it. Minivox types it<span className="text-accent">.</span>
            </h1>
            <p className="mt-7 max-w-xl text-[16px] leading-8 text-secondary">
              A tiny menu-bar app for quick, local dictation. Click, speak, and stop. Minivox turns your voice into text and copies it to the clipboard.
            </p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <a
                href={downloadUrl}
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-accent bg-accent px-5 font-mono text-[11px] font-medium uppercase tracking-[0.08em] text-canvas"
              >
                <Download className="h-3.5 w-3.5" />
                Download Minivox
              </a>
              <Link
                href={sourceUrl}
                target="_blank"
                rel="noreferrer noopener"
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-line-strong bg-panel px-5 font-mono text-[11px] uppercase tracking-[0.08em] text-ink transition-colors hover:text-accent"
              >
                <Github className="h-3.5 w-3.5" />
                View the source
              </Link>
              <Link
                href="/docs/apple-embed"
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-line-strong bg-panel px-5 font-mono text-[11px] uppercase tracking-[0.08em] text-ink transition-colors hover:text-accent"
              >
                Build with Vox
                <ArrowUpRight className="h-3.5 w-3.5" />
              </Link>
            </div>
          </div>

          <div className="mx-auto w-full max-w-[430px]">
            <div className="mb-2 flex items-center justify-end gap-2 px-2 font-mono text-[10px] uppercase tracking-[0.12em] text-muted">
              <span className="inline-flex h-6 w-6 items-center justify-center rounded-full border border-line bg-panel text-accent">M</span>
              menu bar
            </div>
            <div className="overflow-hidden rounded-[22px] border border-line-strong bg-panel shadow-[0_28px_90px_rgba(0,0,0,0.32)]">
              <div className="flex items-center gap-3 border-b border-line bg-canvas px-5 py-4">
                <div className="grid h-9 w-9 place-items-center rounded-xl bg-accent text-canvas">
                  <span className="font-mono text-sm font-semibold">M</span>
                </div>
                <div>
                  <p className="text-[15px] font-semibold">Minivox</p>
                  <p className="text-[11px] text-muted">tiny local dictation</p>
                </div>
                <span className="ml-auto inline-flex items-center gap-2 rounded-full border border-line px-3 py-1 font-mono text-[10px] text-muted">
                  <span className="h-1.5 w-1.5 rounded-full bg-accent" /> ready
                </span>
              </div>

              <div className="p-5">
                <div className="rounded-[20px] border border-line bg-canvas px-5 py-6 text-center">
                  <div className="mx-auto grid h-24 w-24 place-items-center rounded-full border-[7px] border-accent/60 bg-panel shadow-[0_0_50px_rgba(239,92,80,0.14)]">
                    <Mic className="h-7 w-7 text-ink" strokeWidth={1.8} />
                  </div>
                  <p className="mt-4 text-sm font-semibold">Tap to dictate</p>
                  <p className="mt-1 text-[11px] text-muted">Press Space or click the microphone.</p>
                </div>

                <div className="mt-4 rounded-[16px] border border-line bg-canvas p-4">
                  <div className="flex items-center justify-between">
                    <span className="font-mono text-[9px] uppercase tracking-[0.14em] text-muted">Dictation</span>
                    <span className="inline-flex items-center gap-1.5 font-mono text-[9px] uppercase tracking-[0.12em] text-accent">
                      <Check className="h-3 w-3" /> copied
                    </span>
                  </div>
                  <p className="mt-3 text-[13px] leading-6 text-secondary">Meet me outside the studio at half past three.</p>
                  <div className="mt-4 flex gap-4 font-mono text-[9px] uppercase tracking-[0.1em] text-muted">
                    <span>load 0ms</span><span>transcribe 127ms</span><span>total 142ms</span>
                  </div>
                </div>

                <div className="mt-4 flex items-center justify-between px-1 font-mono text-[9px] uppercase tracking-[0.12em] text-muted">
                  <span>Parakeet ready</span>
                  <span>Microphone ready</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-line bg-panel">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// one small job"}</p>
          <h2 className="mt-4 max-w-[22ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
            From your voice to the clipboard in three steps.
          </h2>

          <div className="mt-10 grid grid-cols-1 gap-px overflow-hidden rounded-sm border border-line bg-line sm:grid-cols-3">
            {steps.map(({ idx, icon: Icon, title, body }) => (
              <article key={title} className="bg-canvas p-6">
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[10px] text-muted">{idx}</span>
                  <Icon className="h-4 w-4 text-accent" strokeWidth={1.7} />
                </div>
                <h3 className="mt-5 text-[16px] font-semibold text-ink">{title}</h3>
                <p className="mt-3 text-[14px] leading-7 text-secondary">{body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl gap-10 px-6 py-20 lg:grid-cols-[0.9fr_1.1fr]">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// tiny by design"}</p>
            <h2 className="mt-4 max-w-[18ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
              Small enough to stay out of your way.
            </h2>
            <p className="mt-5 max-w-md text-[15px] leading-7 text-secondary">
              Minivox lives in the menu bar, keeps model readiness visible, and disappears when you are done. It is a direct Vox embed with no daemon, browser bridge, reply engine, or speech-generation step.
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <article className="rounded-sm border border-line bg-panel p-6">
              <Sparkles className="h-5 w-5 text-accent" strokeWidth={1.7} />
              <h3 className="mt-5 text-lg font-semibold text-ink">Automatic clipboard</h3>
              <p className="mt-3 text-[14px] leading-7 text-secondary">
                Stop recording and the finished text is already copied. Paste it wherever you were working.
              </p>
            </article>
            <article className="rounded-sm border border-line bg-panel p-6">
              <Mic className="h-5 w-5 text-accent" strokeWidth={1.7} />
              <h3 className="mt-5 text-lg font-semibold text-ink">Local Parakeet transcription</h3>
              <p className="mt-3 text-[14px] leading-7 text-secondary">
                Audio is recorded and transcribed on the Mac. Warm-up stays an explicit control so the first dictation is predictable.
              </p>
            </article>
          </div>
        </div>
      </section>

      <section className="border-b border-line bg-panel">
        <div className="mx-auto grid max-w-6xl gap-10 px-6 py-20 lg:grid-cols-[1fr_1.1fr] lg:items-center">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// run minivox"}</p>
            <h2 className="mt-4 max-w-[22ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
              Install, then dictate.
            </h2>
            <p className="mt-5 max-w-md text-[15px] leading-7 text-secondary">
              npm and Homebrew install the same signed and notarized release. The installer opens Minivox automatically; look for its waveform in the menu bar.
            </p>
          </div>
          <div>
            <div className="space-y-3">
              <CopyCommand command="npx -y @voxd/cli@latest install mini" />
              <CopyCommand command="brew install --cask arach/vox/minivox" />
            </div>
            <p className="mt-3 font-mono text-[10px] leading-5 text-muted">
              Installs the <span className="text-ink">minivox</span> command too. Add <span className="text-ink">--quiet</span> or <span className="text-ink">--verbose</span> to control setup output.
            </p>
            <div className="mt-6 border-l-2 border-accent pl-5">
              <p className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted">After installation</p>
              <ol className="mt-3 space-y-2 text-[14px] leading-6 text-secondary">
                <li><span className="mr-2 font-mono text-accent">01</span>Put the text cursor where you want your dictation.</li>
                <li><span className="mr-2 font-mono text-accent">02</span>Press <span className="font-mono text-ink">Right ⌘M</span> to start, then allow microphone and Accessibility access.</li>
                <li><span className="mr-2 font-mono text-accent">03</span>Press <span className="font-mono text-ink">Right ⌘M</span> again to stop. Minivox copies the text and pastes it when Accessibility access is enabled.</li>
              </ol>
              <p className="mt-3 text-[12px] leading-5 text-muted">
                The first dictation may download Parakeet. Open <span className="font-mono text-ink">minivox settings</span> to change the shortcut or microphone.
              </p>
            </div>
            <div className="mt-5 flex flex-wrap gap-4 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
              <Link href={sourceUrl} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Source and setup <ArrowUpRight className="h-3 w-3" />
              </Link>
              <Link href="/docs/apple-embed" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Apple embed guide <ArrowUpRight className="h-3 w-3" />
              </Link>
            </div>
          </div>
        </div>
      </section>

      <footer>
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-6 py-10 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:flex-row sm:items-center sm:justify-between">
          <span>Minivox · tiny local dictation</span>
          <div className="flex gap-5">
            <Link href="/" className="transition-colors hover:text-accent">/home</Link>
            <a href={downloadUrl} className="transition-colors hover:text-accent">/download</a>
            <Link href="/docs/apple-embed" className="transition-colors hover:text-accent">/embed</Link>
            <Link href={sourceUrl} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
              <Github className="h-3 w-3" />
              /source
            </Link>
          </div>
        </div>
      </footer>
    </main>
  );
}
