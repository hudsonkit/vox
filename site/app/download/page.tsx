import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowUpRight, Check, CheckCircle2, Download, Github, Mic, ShieldCheck, TerminalSquare } from "lucide-react";
import { CopyCommand } from "../../components/copy-command";

const dmgUrl = "https://github.com/arach/vox/releases/latest/download/Vox.dmg";

export const metadata: Metadata = {
  title: "Download Vox",
  description: "Download Vox Companion for macOS, or install Minivox for quick local dictation.",
  openGraph: {
    title: "Download Vox",
    description: "Download Vox Companion for macOS, or install Minivox for quick local dictation.",
    images: [{ url: "/og.png" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Download Vox",
    description: "Download Vox Companion for macOS, or install Minivox for quick local dictation.",
    images: ["/og.png"],
  },
};

const checks = [
  "Latest signed and notarized Mac installer",
  "Includes Vox, its local service, and the speech worker",
  "Works with the CLI, Node SDK, and browser client",
];

export default function DownloadPage() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      <header className="border-b border-line">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
          <Link href="/" className="flex items-center gap-3">
            <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-accent" />
            <span className="text-[15px] font-medium tracking-tight text-ink">Vox</span>
          </Link>
          <nav className="flex flex-wrap items-center gap-1 font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
            <Link href="/docs/overview" className="px-2.5 py-1.5 transition-colors hover:text-accent">Docs</Link>
            <Link href="/models" className="px-2.5 py-1.5 transition-colors hover:text-accent">Models</Link>
            <Link href="/web" className="px-2.5 py-1.5 transition-colors hover:text-accent">Web SDK</Link>
            <Link href="/minivox" className="px-2.5 py-1.5 transition-colors hover:text-accent">Minivox</Link>
            <Link href="/blog" className="px-2.5 py-1.5 transition-colors hover:text-accent">Blog</Link>
            <Link href="https://github.com/arach/vox" target="_blank" rel="noreferrer noopener" className="px-2.5 py-1.5 transition-colors hover:text-accent">GitHub</Link>
          </nav>
        </div>
      </header>

      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl gap-12 px-6 py-20 lg:grid-cols-[1.15fr_0.85fr] lg:items-start">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// download"}</p>
            <h1 className="mt-5 max-w-[16ch] text-[clamp(2rem,5vw,4rem)] font-medium leading-[1.05] tracking-[-0.04em] text-ink">
              Install Vox Companion for macOS<span className="text-accent">.</span>
            </h1>
            <p className="mt-6 max-w-xl text-[15px] leading-7 text-secondary">
              Vox Companion lets web apps and developer tools use speech models running on your Mac. Install it once, then connect from the browser client, Node SDK, or CLI.
            </p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <Link
                href={dmgUrl}
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-accent bg-accent px-5 font-mono text-[12px] font-medium uppercase tracking-[0.06em] text-canvas"
              >
                <Download className="h-3.5 w-3.5" />
                Download Vox.dmg
              </Link>
              <Link
                href="https://github.com/arach/vox/releases/latest"
                target="_blank"
                rel="noreferrer noopener"
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-line-strong bg-panel px-4 font-mono text-[12px] uppercase tracking-[0.06em] text-ink transition-colors hover:text-accent"
              >
                Release notes
                <ArrowUpRight className="h-3 w-3" />
              </Link>
            </div>
          </div>

          <div className="rounded-sm border border-line-strong bg-panel p-6">
            <div className="flex items-center justify-between border-b border-line pb-4">
              <span className="font-mono text-[11px] uppercase tracking-[0.16em] text-muted">Installer</span>
              <ShieldCheck className="h-4 w-4 text-accent" />
            </div>
            <div className="mt-5 space-y-4">
              {checks.map((check) => (
                <div key={check} className="flex gap-3 text-[14px] leading-6 text-secondary">
                  <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-accent" />
                  <span>{check}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl grid-cols-[minmax(0,1fr)] gap-px px-6 py-20 lg:grid-cols-2">
          <div className="min-w-0 border border-line bg-panel p-8">
            <div className="mb-5 flex items-center gap-3">
              <Download className="h-4 w-4 text-muted" />
              <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted">Mac app</span>
            </div>
            <p className="text-[14px] leading-7 text-secondary">
              Open the DMG, drag Vox to Applications, and launch it. Vox lives in the menu bar and connects web apps and developer tools to local speech.
            </p>
          </div>

          <div className="min-w-0 border border-line bg-panel p-8">
            <div className="mb-5 flex items-center gap-3">
              <TerminalSquare className="h-4 w-4 text-muted" />
              <span className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted">CLI</span>
            </div>
            <CopyCommand command="npm install -g @voxd/cli@latest" />
            <p className="mt-4 text-[14px] leading-7 text-secondary">
              Use the CLI to check your setup, warm up models, run benchmarks, view logs, and generate speech.
            </p>
          </div>
        </div>
      </section>

      <section id="minivox" aria-labelledby="minivox-heading" className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-16">
          <div className="mb-5 flex items-center gap-3 font-mono text-[10px] uppercase tracking-[0.16em] text-muted">
            <span aria-hidden="true" className="h-px w-8 bg-accent" />
            A smaller thing entirely
          </div>

          <div className="overflow-hidden rounded-[18px] border border-line-strong bg-panel shadow-[0_24px_80px_rgba(0,0,0,0.22)]">
            <div className="grid lg:grid-cols-[0.95fr_1.05fr]">
              <div className="p-7 sm:p-9 lg:border-r lg:border-line">
                <div className="flex items-center gap-3">
                  <Image
                    src="/minivox-icon.png"
                    alt=""
                    width={44}
                    height={44}
                    className="h-11 w-11 rounded-[11px] border border-line-strong"
                  />
                  <div>
                    <p className="text-[15px] font-semibold tracking-[-0.015em] text-ink">Minivox</p>
                    <p className="font-mono text-[9px] uppercase tracking-[0.14em] text-muted">tiny macOS dictation</p>
                  </div>
                </div>

                <h2 id="minivox-heading" className="mt-8 max-w-[13ch] text-balance text-[clamp(1.8rem,3.2vw,2.8rem)] font-medium leading-[1.04] tracking-[-0.045em] text-ink">
                  One shortcut. One job<span className="text-accent">.</span>
                </h2>
                <p className="mt-5 max-w-lg text-[14px] leading-7 text-secondary">
                  Vox Companion is the speech runtime for apps and tools. Minivox is the finished, single-purpose app: press a shortcut, dictate, and the text lands where you were typing.
                </p>

                <div className="mt-6 flex flex-wrap gap-2 font-mono text-[9px] uppercase tracking-[0.12em] text-muted">
                  <span className="rounded-full border border-line px-3 py-1.5">Menu bar</span>
                  <span className="rounded-full border border-line px-3 py-1.5">On-device</span>
                  <span className="rounded-full border border-line px-3 py-1.5">Auto-paste</span>
                </div>

                <Link href="/minivox" className="mt-7 inline-flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.12em] text-ink transition-colors hover:text-accent focus-visible:text-accent focus-visible:outline focus-visible:outline-1 focus-visible:outline-offset-4 focus-visible:outline-accent">
                  See Minivox <ArrowUpRight aria-hidden="true" className="h-3 w-3" />
                </Link>
              </div>

              <div className="border-t border-line bg-canvas p-5 sm:p-7 lg:border-t-0">
                <div className="mb-3 flex items-center justify-between font-mono text-[9px] uppercase tracking-[0.14em] text-muted">
                  <span>Quick preview</span>
                  <span>menu bar / idle</span>
                </div>

                <div className="mx-auto max-w-[420px] overflow-hidden rounded-[15px] border border-line-strong bg-panel shadow-[0_24px_70px_rgba(239,68,68,0.06)]">
                  <div className="flex h-14 items-center gap-3 border-b border-line bg-canvas px-4">
                    <Image src="/minivox-icon.png" alt="" width={28} height={28} className="h-7 w-7 rounded-[7px]" />
                    <div>
                      <p className="text-[12px] font-semibold text-ink">Minivox</p>
                      <p className="font-mono text-[8px] uppercase tracking-[0.1em] text-muted">local dictation</p>
                    </div>
                    <span className="ml-auto inline-flex items-center gap-2 rounded-full border border-line px-2.5 py-1 font-mono text-[8px] uppercase tracking-[0.12em] text-muted">
                      <span aria-hidden="true" className="h-1.5 w-1.5 rounded-full bg-accent" /> ready
                    </span>
                  </div>

                  <div className="flex items-center gap-4 border-b border-line px-5 py-5">
                    <div className="relative grid h-14 w-14 shrink-0 place-items-center rounded-full border border-accent/50 bg-canvas shadow-[0_0_32px_rgba(239,68,68,0.08)]">
                      <span aria-hidden="true" className="absolute inset-[5px] rounded-full border border-line" />
                      <Mic aria-hidden="true" className="h-4 w-4 text-ink" strokeWidth={1.7} />
                    </div>
                    <div>
                      <p className="text-[14px] font-medium text-ink">Ready</p>
                      <p className="mt-1 font-mono text-[9px] tracking-[0.04em] text-muted">Click or press shortcut</p>
                    </div>
                  </div>

                  <div className="flex min-h-20 items-start justify-between gap-5 px-5 py-4">
                    <div>
                      <p className="font-mono text-[8px] uppercase tracking-[0.14em] text-muted">Transcription</p>
                      <p className="mt-2 text-[12px] leading-5 text-secondary">Meet me outside at half past three.</p>
                    </div>
                    <span className="inline-flex shrink-0 items-center gap-1.5 font-mono text-[8px] uppercase tracking-[0.12em] text-accent">
                      <Check aria-hidden="true" className="h-3 w-3" /> pasted
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <div className="grid gap-4 border-t border-line bg-canvas p-5 sm:p-6 lg:grid-cols-[0.55fr_1.45fr] lg:items-center">
              <div>
                <p className="font-mono text-[9px] uppercase tracking-[0.16em] text-muted">Install Minivox</p>
                <p className="mt-2 text-[13px] text-secondary">Same tiny app and command, 2 routes.</p>
              </div>
              <div className="grid min-w-0 gap-3">
                <div className="grid min-w-0 gap-2 sm:grid-cols-[5rem_minmax(0,1fr)] sm:items-center">
                  <span className="font-mono text-[9px] uppercase tracking-[0.14em] text-muted">npm</span>
                  <CopyCommand command="npx -y @voxd/cli@latest install mini" />
                </div>
                <div className="grid min-w-0 gap-2 sm:grid-cols-[5rem_minmax(0,1fr)] sm:items-center">
                  <span className="font-mono text-[9px] uppercase tracking-[0.14em] text-muted">Homebrew</span>
                  <CopyCommand command="brew install --cask arach/vox/minivox" />
                </div>
                <p className="text-[11px] leading-5 text-secondary">
                  After installation, use the waveform in the menu bar: put your cursor in any text field, press <span className="font-mono text-ink">Right ⌘M</span> to start, then press it again to transcribe and paste.
                </p>
                <p className="font-mono text-[9px] text-muted">The first use asks for microphone access. npm setup also accepts --quiet or --verbose.</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <footer>
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-6 py-10 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:flex-row sm:items-center sm:justify-between">
          <span>voxd.cc/download</span>
          <div className="flex gap-5">
            <Link href="/docs/quickstart" className="transition-colors hover:text-accent">/quickstart</Link>
            <Link href="https://github.com/arach/vox" target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
              <Github className="h-3 w-3" />
              /github
            </Link>
          </div>
        </div>
      </footer>
    </main>
  );
}
