import Link from "next/link";
import { ArrowUpRight, Download, Github } from "lucide-react";
import { CopyCommand } from "../components/copy-command";
import { ScreenshotLightbox } from "../components/screenshot-lightbox";
import cliPkg from "../../packages/cli/package.json";

const VOX_VERSION = cliPkg.version;
const VOX_RELEASE_URL = `https://github.com/arach/vox/releases/tag/v${VOX_VERSION}`;

const featureRows = [
  { idx: "01", title: "Transcription", body: "Turn recorded files or live microphone audio into text, with word timings when you need them." },
  { idx: "02", title: "Text-to-speech", body: "Turn text into spoken audio with Apple system voices, local models, or a configured speech provider." },
  { idx: "03", title: "Local by design", body: "Run Vox inside an Apple app, or connect browser and Node clients through Vox Companion on the same Mac." },
  { idx: "04", title: "Warm and measurable", body: "Prepare models before the first request and see how long loading, inference, and synthesis take." },
  { idx: "05", title: "Catalog and plugins", body: "Read dictation models from published JSON. Built-in families load in Vox. New families install as plugins." },
];

const surfaceCards = [
  { eyebrow: "SWIFT PACKAGES", title: "VoxCore · VoxEngine · VoxService · VoxBridge", body: "Embed transcription and text-to-speech directly in macOS and iOS apps.", href: "/docs/overview", cta: "Open the overview" },
  { eyebrow: "COMPANION SERVICE", title: "voxd", body: "Keep speech models ready on your Mac and share them with browser apps, Node tools, and the CLI.", href: "/docs/runtime", cta: "Read runtime docs" },
  { eyebrow: "BUN AND NODE SDK", title: "@voxd/sdk", body: "Transcribe audio and generate speech from typed Bun and Node clients.", href: "/docs/sdk", cta: "See the SDK" },
  { eyebrow: "BROWSER SDK", title: "@voxd/client", body: "Add local transcription to web apps through Vox Companion.", href: "/web", cta: "Explore the web SDK" },
  { eyebrow: "COMMAND-LINE TOOLS", title: "@voxd/cli", body: "Transcribe files, generate speech, refresh the model catalog, install plugins, and measure performance from the terminal.", href: "/docs/quickstart", cta: "Quickstart" },
];

const relatedProjects = [
  { name: "TALKIE", href: "https://usetalkie.com", body: "A voice app built on the same local-first foundation." },
  { name: "LINEA", href: "https://uselinea.com", body: "A native client for local, private workflows." },
  { name: "LATTICES", href: "https://lattices.dev", body: "Tools for running agent workflows locally." },
];

export default function Home() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      {/* Sticky status strip */}
      <div className="sticky top-0 z-50 border-b border-line bg-canvas">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-2 font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
          <Link
            href={VOX_RELEASE_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="text-secondary transition-colors hover:text-accent"
          >
            vox v{VOX_VERSION}
          </Link>
          <span className="hidden items-center gap-2 text-secondary sm:inline-flex">
            <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-accent" />
            transcription · text-to-speech
          </span>
          <span>local · ready · measurable</span>
        </div>
      </div>

      {/* Nav */}
      <header className="border-b border-line">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
          <Link href="/" className="flex items-center gap-3">
            <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-accent" />
            <span className="text-[15px] font-medium tracking-tight text-ink">Vox</span>
          </Link>
          <nav aria-label="Primary" className="hidden items-center gap-1 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:flex">
            <Link href="/docs/overview" className="px-2.5 py-1.5 transition-colors hover:text-accent">Docs</Link>
            <Link href="/models" className="px-2.5 py-1.5 transition-colors hover:text-accent">Models</Link>
            <Link href="/download" className="px-2.5 py-1.5 transition-colors hover:text-accent">Download</Link>
            <Link href="/blog" className="px-2.5 py-1.5 transition-colors hover:text-accent">Blog</Link>
            <Link href="#capabilities" className="px-2.5 py-1.5 transition-colors hover:text-accent">Capabilities</Link>
            <Link href="#packages" className="px-2.5 py-1.5 transition-colors hover:text-accent">Packages</Link>
            <Link href="/minivox" className="px-2.5 py-1.5 transition-colors hover:text-accent">Minivox</Link>
            <Link href="#perf" className="px-2.5 py-1.5 transition-colors hover:text-accent">Perf</Link>
            <Link href="https://github.com/arach/vox" target="_blank" rel="noreferrer noopener" className="px-2.5 py-1.5 transition-colors hover:text-accent">GitHub</Link>
          </nav>
          <nav aria-label="Primary mobile" className="flex items-center gap-1 font-mono text-[10px] uppercase tracking-[0.12em] text-muted sm:hidden">
            <Link href="/docs/overview" className="px-2 py-1.5 transition-colors hover:text-accent">Docs</Link>
            <Link href="/models" className="px-2 py-1.5 transition-colors hover:text-accent">Models</Link>
            <Link href="/minivox" className="px-2 py-1.5 transition-colors hover:text-accent">Minivox</Link>
            <Link href="https://github.com/arach/vox" target="_blank" rel="noreferrer noopener" className="px-2 py-1.5 transition-colors hover:text-accent">GitHub</Link>
          </nav>
        </div>
      </header>

      {/* Hero */}
      <section className="border-b border-line">
        <div className="mx-auto grid max-w-6xl gap-12 px-6 py-20 lg:grid-cols-[1.25fr_1fr] lg:gap-16">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// hero"}</p>
            <h1 className="mt-5 max-w-[22ch] text-[clamp(1.75rem,3.8vw,2.75rem)] font-medium leading-[1.15] tracking-[-0.03em] text-ink">
              Vox powers macOS transcription and text-to-speech<span className="text-accent">.</span>
            </h1>
            <p className="mt-6 max-w-md text-[15px] leading-7 text-secondary">
              For macOS, iOS, and web apps. Embed Vox directly or integrate through Vox Companion.
            </p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <Link
                href="/docs/apple-embed"
                className="inline-flex h-10 items-center gap-2 rounded-sm border border-accent bg-accent px-5 font-mono text-[12px] font-medium uppercase tracking-[0.06em] text-canvas"
              >
                <ArrowUpRight className="h-3.5 w-3.5" />
                Explore the docs
              </Link>
              <Link
                href="/minivox"
                className="inline-flex h-10 items-center gap-2 rounded-sm border border-line-strong bg-panel px-4 font-mono text-[12px] uppercase tracking-[0.06em] text-ink transition-colors hover:text-accent"
              >
                Try Minivox
                <ArrowUpRight className="h-3 w-3" />
              </Link>
            </div>

            <div className="mt-8 max-w-md">
              <CopyCommand command="npm install -g @voxd/cli@latest" />
              <p className="mt-2 font-mono text-[10px] tracking-wide text-muted">
                transcribe · speak · warm-up · measure
              </p>
            </div>
          </div>

          {/* Operator window */}
          <div className="self-start overflow-hidden rounded-sm border border-line-strong bg-panel">
            <div className="flex items-center gap-2 border-b border-line bg-canvas px-3 py-2.5">
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span className="ml-auto font-mono text-[11px] text-muted">vox-operator</span>
            </div>
            <div className="p-4 font-mono text-[12.5px] leading-7">
              <div className="text-muted">$ vox transcribe file --metrics /tmp/sample.wav</div>
              <div className="text-ink">done · 127ms · &quot;hello from Vox&quot;</div>
              <div className="mt-2.5 text-muted">$ vox models catalog</div>
              <div className="text-ink">parakeet:v3 · gpt-transcribe · gemma-4-e2b-it</div>
              <div className="mt-2.5 text-muted">$ vox plugins install mlx-vlm</div>
              <div className="text-ink">plugin ready · restart voxd</div>
            </div>
          </div>
        </div>
      </section>

      {/* Capabilities */}
      <section id="capabilities" className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <div className="flex items-baseline justify-between">
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// capabilities"}</p>
            <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">5 capabilities</span>
          </div>
          <h2 className="mt-4 max-w-[30ch] text-[clamp(1.5rem,2.6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-ink">
            Audio to text. Text back to audio.
          </h2>

          <div className="mt-10 rounded-sm border border-line">
            {featureRows.map(({ idx, title, body }, i) => (
              <article
                key={title}
                className={`grid items-start grid-cols-[3.5rem_1fr] sm:grid-cols-[3.5rem_minmax(0,260px)_1fr] ${i === featureRows.length - 1 ? "" : "border-b border-line"}`}
              >
                <div className="border-r border-line px-3 py-5 text-right font-mono text-[11px] text-muted">{idx}</div>
                <div className="px-6 py-5 font-medium text-ink sm:border-r sm:border-line">{title}</div>
                <p className="col-span-2 border-t border-line px-6 py-5 text-[14px] leading-7 text-secondary sm:col-span-1 sm:border-l-0 sm:border-t-0">
                  {body}
                </p>
              </article>
            ))}
          </div>
        </div>
      </section>

      {/* Packages */}
      <section id="packages" className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <div className="flex items-baseline justify-between">
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// packages"}</p>
            <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">5 surfaces</span>
          </div>
          <h2 className="mt-4 max-w-[26ch] text-[clamp(1.5rem,2.6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-ink">
            Build with Vox wherever your voice workflow lives.
          </h2>
          <p className="mt-4 max-w-2xl text-[15px] leading-7 text-secondary">
            Apple apps can run the engine directly. Browser apps and local tools connect through Vox Companion. Each surface keeps transcription and speech generation explicit.
          </p>

          <div className="mt-10 rounded-sm border border-line">
            {surfaceCards.map((card, i) => (
              <article
                key={card.title}
                className={`grid items-start grid-cols-1 sm:grid-cols-[minmax(0,180px)_1fr_minmax(0,200px)] ${i === surfaceCards.length - 1 ? "" : "border-b border-line"}`}
              >
                <div className="border-b border-line px-5 py-5 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:border-b-0 sm:border-r">
                  {card.eyebrow}
                </div>
                <div className="px-6 py-5">
                  <h3 className="text-[15px] font-semibold tracking-[-0.01em] text-ink">{card.title}</h3>
                  <p className="mt-2 text-[14px] leading-7 text-secondary">{card.body}</p>
                </div>
                <div className="border-t border-line px-5 py-5 sm:border-l sm:border-t-0">
                  <Link
                    href={card.href}
                    className="group inline-flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.14em] text-muted transition-colors hover:text-accent"
                  >
                    → {card.cta}
                    <ArrowUpRight className="h-3 w-3 opacity-50 transition-all group-hover:-translate-y-px group-hover:translate-x-px group-hover:opacity-100" />
                  </Link>
                </div>
              </article>
            ))}
          </div>
        </div>
      </section>

      {/* Minivox */}
      <section id="minivox" className="border-b border-line bg-panel">
        <div className="mx-auto grid max-w-6xl gap-12 px-6 py-20 lg:grid-cols-[1fr_1.4fr] lg:items-start">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// minivox"}</p>
            <h2 className="mt-4 max-w-[22ch] text-[clamp(1.5rem,2.6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-ink">
              Minivox is the smallest possible dictation thing.
            </h2>
            <p className="mt-4 max-w-md text-[15px] leading-7 text-secondary">
              Open source and hackable. Press a shortcut, speak, and Minivox transcribes locally with Parakeet and pastes the text.
            </p>
            <p className="mt-4 max-w-md text-[14px] leading-7 text-secondary">
              Tell your agents to embed it in your favorite project. It is a few Swift files on Vox, with no daemon or browser bridge.
            </p>
            <div className="mt-7 flex flex-wrap items-center gap-3 font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
              <span className="inline-flex items-center gap-2 rounded-sm border border-line-strong bg-canvas px-3 py-1.5">
                <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-accent" />
                Open source
              </span>
              <span className="inline-flex items-center gap-2 rounded-sm border border-line-strong bg-canvas px-3 py-1.5">
                Parakeet
              </span>
              <span className="inline-flex items-center gap-2 rounded-sm border border-line-strong bg-canvas px-3 py-1.5">
                Auto-copy
              </span>
              <span className="inline-flex items-center gap-2 rounded-sm border border-line-strong bg-canvas px-3 py-1.5">
                Menu bar
              </span>
            </div>
            <Link
              href="/minivox"
              className="mt-7 inline-flex h-10 items-center gap-2 rounded-sm border border-accent bg-accent px-5 font-mono text-[11px] font-medium uppercase tracking-[0.08em] text-canvas"
            >
              Meet Minivox
              <ArrowUpRight className="h-3.5 w-3.5" />
            </Link>
          </div>
          <div className="overflow-hidden rounded-sm border border-line-strong bg-canvas shadow-[0_24px_80px_rgba(0,0,0,0.22)]">
            <div className="flex items-center gap-2 border-b border-line px-3 py-2.5">
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span className="ml-auto font-mono text-[11px] text-muted">Minivox</span>
            </div>
            <div className="p-6">
              <div className="flex flex-wrap gap-2 font-mono text-[10px] uppercase tracking-[0.12em] text-muted">
                <span className="rounded-full border border-line px-3 py-1">Parakeet ready</span>
                <span className="rounded-full border border-line px-3 py-1">Microphone ready</span>
                <span className="rounded-full border border-line px-3 py-1">Auto-copy on</span>
              </div>
              <div className="mt-6 flex justify-center">
                <div className="grid h-28 w-28 place-items-center rounded-full border-[7px] border-accent/70 bg-panel text-center font-mono text-[10px] uppercase tracking-[0.12em] text-secondary shadow-[0_0_50px_rgba(239,92,80,0.12)]">
                  Press<br />to talk
                </div>
              </div>
              <div className="mt-6 grid gap-3">
                <div className="rounded-sm border border-line bg-panel px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-[0.12em] text-muted">You · transcript</p>
                  <p className="mt-2 text-[13px] leading-6 text-secondary">Meet me outside the studio at half past three.</p>
                </div>
                <div className="rounded-sm border border-line bg-panel px-4 py-3">
                  <p className="font-mono text-[10px] uppercase tracking-[0.12em] text-accent">Copied to clipboard</p>
                  <p className="mt-2 text-[13px] leading-6 text-secondary">Ready to paste into any app.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Related */}
      <section className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// related"}</p>
          <h2 className="mt-4 text-[clamp(1.5rem,2.6vw,2rem)] font-semibold tracking-[-0.02em] text-ink">
            A few related projects.
          </h2>

          <div className="mt-10 grid grid-cols-1 rounded-sm border border-line sm:grid-cols-3">
            {relatedProjects.map((project, i) => (
              <Link
                key={project.name}
                href={project.href}
                target="_blank"
                rel="noreferrer noopener"
                className={`group block px-6 py-5 transition-colors hover:bg-panel ${i === relatedProjects.length - 1 ? "" : "border-b border-line sm:border-b-0 sm:border-r"}`}
              >
                <div className="flex items-center justify-between">
                  <span className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted transition-colors group-hover:text-accent">{project.name}</span>
                  <ArrowUpRight className="h-3.5 w-3.5 text-muted transition-colors group-hover:text-accent" />
                </div>
                <p className="mt-3 text-[14px] leading-7 text-secondary">{project.body}</p>
                <p className="mt-3 font-mono text-[10px] tracking-[0.14em] text-muted">
                  {project.href.replace("https://", "")}
                </p>
              </Link>
            ))}
          </div>
        </div>
      </section>

      {/* Observability */}
      <section id="perf" className="border-b border-line bg-panel">
        <div className="mx-auto grid max-w-6xl gap-12 px-6 py-20 lg:grid-cols-2 lg:items-start">
          <div>
            <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// observability"}</p>
            <h2 className="mt-4 max-w-[22ch] text-[clamp(1.5rem,2.6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-ink">
              See where the time goes.
            </h2>
            <p className="mt-4 max-w-md text-[15px] leading-7 text-secondary">
              See how long each part of a voice request takes. Filter results by app, route, model, or voice.
            </p>
            <div className="mt-7 max-w-xs">
              <CopyCommand command="vox tui" />
            </div>
          </div>
          <div className="overflow-hidden rounded-sm border border-line-strong bg-canvas">
            <div className="flex items-center gap-2 border-b border-line px-3 py-2.5">
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-line-strong" />
              <span className="ml-auto font-mono text-[11px] text-muted">vox tui</span>
            </div>
            <ScreenshotLightbox
              src="/tui-dashboard.png"
              alt="Vox dashboard showing performance stats, per-client breakdown, and recent voice activity"
              title="vox tui"
              caption="Performance dashboard with a per-client breakdown and recent voice activity."
            />
          </div>
        </div>
      </section>

      {/* Get started */}
      <section className="border-b border-line">
        <div className="mx-auto max-w-6xl px-6 py-20">
          <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-muted">{"// install"}</p>
          <h2 className="mt-4 max-w-[30ch] text-[clamp(1.5rem,2.6vw,2rem)] font-semibold leading-tight tracking-[-0.02em] text-ink">
            Add Vox Companion to your Mac.
          </h2>
          <p className="mt-4 max-w-2xl text-[15px] leading-7 text-secondary">
            Apple apps can use Vox directly. For web apps and local tools, install Vox Companion, then use the CLI to check that it is ready or measure performance.
          </p>

          <div className="mt-10 grid grid-cols-1 rounded-sm border border-line lg:grid-cols-2">
            <div className="border-b border-line px-6 py-7 lg:border-b-0 lg:border-r">
              <p className="font-mono text-[11px] uppercase tracking-[0.16em] text-muted">DOWNLOAD</p>
              <p className="mt-3 text-[14px] leading-7 text-secondary">
                Drag Vox to Applications. It opens at login so web apps and local tools can connect when needed.
              </p>
              <Link
                href="/download"
                className="mt-5 inline-flex h-9 items-center gap-2 rounded-sm border border-line-strong bg-panel px-4 font-mono text-[11px] uppercase tracking-[0.06em] text-ink transition-colors hover:text-accent"
              >
                <Download className="h-3 w-3" />
                Vox.dmg
              </Link>
            </div>
            <div className="px-6 py-7">
              <p className="font-mono text-[11px] uppercase tracking-[0.16em] text-muted">CLI</p>
              <div className="mt-3 font-mono text-[12.5px] leading-7">
                <div className="text-muted">$ npx -y @voxd/cli install</div>
                <div className="text-secondary">registers Vox.app or ~/.vox/bin/voxd as a LaunchAgent</div>
                <div className="mt-2.5 text-muted">$ npx -y @voxd/cli doctor</div>
                <div className="text-ink">daemon: running</div>
                <div className="text-ink">backend: parakeet</div>
                <div className="text-ink">ready</div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer>
        <div className="mx-auto flex max-w-6xl flex-col gap-4 px-6 py-10 font-mono text-[11px] uppercase tracking-[0.14em] text-muted sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-3">
            <span aria-hidden="true" className="inline-block h-2 w-2 rounded-sm bg-accent" />
            <span className="text-ink">vox</span>
            <span>v{VOX_VERSION} · local-first</span>
          </div>
          <div className="flex gap-5">
            <Link href="/docs/overview" className="transition-colors hover:text-accent">/docs</Link>
            <Link href="/minivox" className="transition-colors hover:text-accent">/minivox</Link>
            <Link href="/download" className="transition-colors hover:text-accent">/download</Link>
            <Link href="/blog" className="transition-colors hover:text-accent">/blog</Link>
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
