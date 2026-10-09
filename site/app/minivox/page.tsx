import type { Metadata } from "next";
import Link from "next/link";
import {
  ArrowLeft,
  ArrowUpRight,
  ClipboardCheck,
  Command,
  Download,
  Github,
  Mic,
  TextCursorInput,
} from "lucide-react";
import { CopyCommand, CopyPrompt } from "../../components/copy-command";
import { DictationIndicator } from "../../components/dictation-indicator";

export const metadata: Metadata = {
  title: "Minivox · The smallest possible dictation thing",
  description: "Minivox is the smallest possible dictation thing: open source, hackable, and easy to embed in your own project.",
  openGraph: {
    title: "Minivox · The smallest possible dictation thing",
    description: "Open source and hackable. Tell your agents to embed it in your favorite project.",
    images: [{ url: "/og/minivox.png" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Minivox · The smallest possible dictation thing",
    description: "Open source and hackable. Tell your agents to embed it in your favorite project.",
    images: ["/og/minivox.png"],
  },
};

const sourceUrl = "https://github.com/hudsonkit/vox/tree/main/apps/minivox";
const downloadUrl = "https://github.com/hudsonkit/vox/releases/latest/download/Minivox.dmg";

const embedPrompt = `Embed Minivox-style dictation in this project.

Read the Minivox source at ${sourceUrl} and https://voxd.cc/docs/start-swift. Add the Vox Swift package (VoxCore and VoxEngine) and use VoxDictation: warmUp() when the user shows intent, start() on one shortcut, stop() on the next, then paste result.text where the cursor is. Keep it as small as Minivox.`;

const sourceFiles = [
  { file: "MinivoxModel.swift", role: "record, transcribe, paste" },
  { file: "MinivoxNotch.swift", role: "the recording notch" },
  { file: "MinivoxLivePreview.swift", role: "words as you speak" },
  { file: "MinivoxPreferences.swift", role: "shortcut and settings" },
  { file: "ContentView.swift", role: "menu-bar popover" },
  { file: "MinivoxMenuPages.swift", role: "history and settings pages" },
  { file: "MinivoxCommandReceiver.swift", role: "commands from the CLI" },
  { file: "MinivoxStyle.swift", role: "colors and type" },
  { file: "MinivoxApp.swift", role: "app entry" },
];

const steps = [
  { idx: "01", icon: Command, title: "Press", body: "Right ⌘M opens the notch and starts recording, from any app." },
  { idx: "02", icon: Mic, title: "Speak", body: "Your words stream into the notch as you talk, transcribed on your Mac." },
  { idx: "03", icon: TextCursorInput, title: "Paste", body: "Press again. Parakeet finishes the take and the text lands at your cursor." },
];

export default function MinivoxPage() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      <div className="border-b border-line bg-canvas">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-2 font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
          <span>Minivox</span>
          <span className="hidden items-center gap-2 text-secondary sm:inline-flex">
            <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-accent" />
            open source
          </span>
          <span>hackable</span>
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
            <Link href="/models" className="hidden px-2.5 py-1.5 transition-colors hover:text-accent sm:inline-flex">Models</Link>
            <Link href="/docs/start-swift" className="px-2.5 py-1.5 transition-colors hover:text-accent">Embed guide</Link>
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
            <p className="mt-9 font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// minivox"}</p>
            <h1 className="mt-5 max-w-[14ch] text-[clamp(2.5rem,5.4vw,4.8rem)] font-medium leading-[0.98] tracking-[-0.05em] text-ink">
              The smallest possible dictation thing<span className="text-accent">.</span>
            </h1>
            <p className="mt-7 max-w-xl text-[16px] leading-8 text-secondary">
              Open source and hackable. Press a shortcut, speak, and Minivox transcribes on your Mac and pastes the text. Use it as is, or tell your agents to embed it in your favorite project.
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
                href="/docs/start-swift"
                className="inline-flex h-11 items-center gap-2 rounded-sm border border-line-strong bg-panel px-5 font-mono text-[11px] uppercase tracking-[0.08em] text-ink transition-colors hover:text-accent"
              >
                Embed it
                <ArrowUpRight className="h-3.5 w-3.5" />
              </Link>
            </div>
          </div>

          <DictationIndicator />
        </div>
      </section>

      <section className="border-b border-line bg-panel">
        <div className="mx-auto grid max-w-6xl gap-12 px-6 py-20 lg:grid-cols-[1fr_1.1fr]">
          <div className="min-w-0">
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// hand it to your agent"}</p>
            <h2 className="mt-4 max-w-[20ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
              Tell your agents to embed it in your favorite project.
            </h2>
            <p className="mt-5 max-w-md text-[15px] leading-7 text-secondary">
              Minivox is nine Swift files on top of Vox, small enough for an agent to read in one pass. Paste the prompt into Claude Code, Codex, or whatever you build with.
            </p>
            <div className="mt-8 border border-line bg-canvas">
              <div className="flex items-center justify-between border-b border-line px-4 py-2.5 font-mono text-[10px] uppercase tracking-[0.14em] text-muted">
                <span>apps/minivox/Sources</span>
                <span>{sourceFiles.length} files</span>
              </div>
              <ul className="divide-y divide-line">
                {sourceFiles.map(({ file, role }) => (
                  <li key={file} className="flex items-center justify-between gap-4 px-4 py-2 font-mono text-[11px]">
                    <span className="truncate text-ink">{file}</span>
                    <span className="shrink-0 text-muted">{role}</span>
                  </li>
                ))}
              </ul>
            </div>
          </div>
          <div className="min-w-0 lg:pt-10">
            <CopyPrompt label="Prompt for your agent" prompt={embedPrompt} />
            <div className="mt-5 flex flex-wrap gap-4 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
              <Link href={sourceUrl} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Read the source <ArrowUpRight className="h-3 w-3" />
              </Link>
              <Link href="/docs/start-swift" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Swift guide <ArrowUpRight className="h-3 w-3" />
              </Link>
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// one small job"}</p>
          <h2 className="mt-4 max-w-[22ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
            From your voice to your cursor in three steps.
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

      <section className="border-b border-line bg-panel">
        <div className="mx-auto grid max-w-6xl gap-10 px-6 py-20 lg:grid-cols-[0.9fr_1.1fr]">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// small on purpose"}</p>
            <h2 className="mt-4 max-w-[18ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
              Nothing to take apart before you start.
            </h2>
            <p className="mt-5 max-w-md text-[15px] leading-7 text-secondary">
              Minivox embeds Vox directly: no daemon, browser bridge, reply engine, or speech-generation step. Fork it, change the shortcut or the notch, and it is still yours to read in an afternoon.
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <article className="rounded-sm border border-line bg-panel p-6">
              <ClipboardCheck className="h-5 w-5 text-accent" strokeWidth={1.7} />
              <h3 className="mt-5 text-lg font-semibold text-ink">Pastes where you type</h3>
              <p className="mt-3 text-[14px] leading-7 text-secondary">
                Stop recording and the text goes straight into the app you were in. It stays on the clipboard too, in case you want it twice.
              </p>
            </article>
            <article className="rounded-sm border border-line bg-panel p-6">
              <Mic className="h-5 w-5 text-accent" strokeWidth={1.7} />
              <h3 className="mt-5 text-lg font-semibold text-ink">Local Parakeet transcription</h3>
              <p className="mt-3 text-[14px] leading-7 text-secondary">
                Audio never leaves the Mac. Minivox warms the model up ahead of time, so even a long first take comes back in a moment.
              </p>
            </article>
          </div>
        </div>
      </section>

      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl gap-10 px-6 py-20 lg:grid-cols-[1fr_1.1fr] lg:items-center">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// run minivox"}</p>
            <h2 className="mt-4 max-w-[22ch] text-[clamp(1.7rem,3vw,2.5rem)] font-semibold leading-tight tracking-[-0.03em] text-ink">
              Install, then dictate.
            </h2>
            <p className="mt-5 max-w-md text-[15px] leading-7 text-secondary">
              One command installs the signed and notarized app and opens it; look for its waveform in the menu bar.
            </p>
          </div>
          <div>
            <CopyCommand command="bunx @voxd/cli@latest install mini" />
            <p className="mt-3 font-mono text-[10px] leading-5 text-muted">
              Installs the <span className="text-ink">minivox</span> command too. Add <span className="text-ink">--quiet</span> or <span className="text-ink">--verbose</span> to control setup output.
            </p>
            <div className="mt-6 border-l-2 border-accent pl-5">
              <p className="font-mono text-[10px] uppercase tracking-[0.16em] text-muted">After installation</p>
              <ol className="mt-3 space-y-2 text-[14px] leading-6 text-secondary">
                <li><span className="mr-2 font-mono text-accent">01</span>Put the text cursor where you want your dictation.</li>
                <li><span className="mr-2 font-mono text-accent">02</span>Press <span className="font-mono text-ink">Right ⌘M</span> to start, then allow microphone and Accessibility access.</li>
                <li><span className="mr-2 font-mono text-accent">03</span>Press <span className="font-mono text-ink">Right ⌘M</span> again to stop. Minivox pastes the text at your cursor and leaves a copy on the clipboard.</li>
              </ol>
              <p className="mt-3 text-[12px] leading-5 text-muted">
                The first dictation may download Parakeet. Open <span className="font-mono text-ink">minivox settings</span> to change the shortcut or microphone.
              </p>
            </div>
            <div className="mt-5 flex flex-wrap gap-4 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
              <Link href={sourceUrl} target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Source and setup <ArrowUpRight className="h-3 w-3" />
              </Link>
              <Link href="/docs/start-swift" className="inline-flex items-center gap-2 transition-colors hover:text-accent">
                Swift guide <ArrowUpRight className="h-3 w-3" />
              </Link>
            </div>
          </div>
        </div>
      </section>

      <footer>
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-6 py-10 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:flex-row sm:items-center sm:justify-between">
          <span>Minivox · the smallest possible dictation thing</span>
          <div className="flex gap-5">
            <Link href="/" className="transition-colors hover:text-accent">/home</Link>
            <a href={downloadUrl} className="transition-colors hover:text-accent">/download</a>
            <Link href="/docs/start-swift" className="transition-colors hover:text-accent">/embed</Link>
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
