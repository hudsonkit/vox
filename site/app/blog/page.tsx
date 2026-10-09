import type { Metadata } from "next";
import Link from "next/link";
import { ArrowUpRight, Github } from "lucide-react";
import { posts } from "./posts";

export const metadata: Metadata = {
  title: "Blog - Vox",
  description: "Updates, technical deep dives, and announcements from the Vox project.",
  openGraph: {
    title: "Blog - Vox",
    description: "Updates, technical deep dives, and announcements from the Vox project.",
    images: [{ url: "/og/blog.png" }],
  },
  twitter: {
    card: "summary_large_image",
    title: "Blog - Vox",
    description: "Updates, technical deep dives, and announcements from the Vox project.",
    images: ["/og/blog.png"],
  },
};

function formatDate(dateStr: string) {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}

export default function BlogIndex() {
  return (
    <main className="min-h-screen bg-canvas text-ink">
      <header className="sticky top-0 z-50 border-b border-line bg-canvas/92 backdrop-blur-xl px-6 sm:px-8 lg:px-12">
        <div className="mx-auto flex max-w-6xl items-center justify-between py-3">
          <div className="flex items-center gap-3 font-mono text-[12px] uppercase tracking-[0.14em]">
            <Link href="/" className="flex items-center gap-2 text-ink">
              <img src="/logo.svg" alt="Vox" className="h-5 w-5" />
              Vox
            </Link>
            <span className="text-muted">/</span>
            <span className="text-muted">Blog</span>
          </div>

          <div className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
            <Link href="/docs/overview" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Docs
            </Link>
            <Link href="/models" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Models
            </Link>
            <Link href="/blog" className="rounded-md px-3 py-2 text-ink transition-colors hover:bg-wave">
              Blog
            </Link>
            <Link href="https://github.com/hudsonkit/vox" target="_blank" rel="noreferrer noopener" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              GitHub
            </Link>
          </div>
        </div>
      </header>

      <section className="px-6 pb-20 pt-16 sm:px-8 lg:px-12">
        <div className="mx-auto max-w-3xl">
          <h1 className="font-display text-4xl italic leading-tight tracking-[-0.03em] sm:text-5xl">
            Blog
          </h1>
          <p className="mt-4 text-[15px] leading-7 text-secondary">
            Technical updates and announcements from the Vox project.
          </p>

          <div className="mt-14 space-y-10">
            {posts.map((post) => (
              <article key={post.slug} className="group">
                <Link href={`/blog/${post.slug}`} className="block">
                  <time className="font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
                    {formatDate(post.date)}
                  </time>
                  <h2 className="mt-2 font-display text-2xl italic leading-snug tracking-tight transition-colors group-hover:text-accent sm:text-3xl">
                    {post.title}
                  </h2>
                  <p className="mt-3 text-[15px] leading-7 text-secondary">
                    {post.summary}
                  </p>
                  <span className="mt-3 inline-flex items-center gap-1 font-mono text-[11px] uppercase tracking-[0.12em] text-accent transition-colors group-hover:text-accent-bright">
                    Read post
                    <ArrowUpRight className="h-3 w-3 transition-transform group-hover:-translate-y-px group-hover:translate-x-px" />
                  </span>
                </Link>
              </article>
            ))}
          </div>
        </div>
      </section>

      <footer className="px-6 pb-28 pt-14 sm:px-8 lg:px-12">
        <div className="mx-auto flex max-w-3xl flex-col gap-6 border-t border-line pt-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <div className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.18em] text-muted">
              <img src="/logo.svg" alt="Vox" className="h-6 w-6" />
              Vox
            </div>
            <p className="mt-2 max-w-sm text-sm leading-7 text-secondary">
              Open-source local voice stack for Apple platforms.
            </p>
          </div>
          <div className="flex gap-5 font-mono text-[10px] uppercase tracking-[0.16em] text-muted">
            <Link href="/docs/overview" className="transition-colors hover:text-ink">
              Docs
            </Link>
            <Link href="https://github.com/hudsonkit/vox" target="_blank" rel="noreferrer noopener" className="inline-flex items-center gap-2 transition-colors hover:text-ink">
              <Github className="h-3.5 w-3.5" />
              GitHub
            </Link>
          </div>
        </div>
      </footer>
    </main>
  );
}
