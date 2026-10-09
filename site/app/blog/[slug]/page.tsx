import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, Github } from "lucide-react";
import { posts, getPost } from "../posts";
import { notFound } from "next/navigation";

export function generateStaticParams() {
  return posts.map((post) => ({ slug: post.slug }));
}

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) return {};
  return {
    title: `${post.title} - Vox`,
    description: post.summary,
    openGraph: {
      title: `${post.title} - Vox`,
      description: post.summary,
      images: [{ url: `/og/blog/${post.slug}.png` }],
    },
    twitter: {
      card: "summary_large_image",
      title: `${post.title} - Vox`,
      description: post.summary,
      images: [`/og/blog/${post.slug}.png`],
    },
  };
}

function formatDate(dateStr: string) {
  const d = new Date(dateStr + "T00:00:00");
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}

function renderContent(content: string) {
  const blocks: React.ReactNode[] = [];
  const lines = content.split("\n");
  let i = 0;
  let key = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Heading
    if (line.startsWith("## ")) {
      blocks.push(
        <h2
          key={key++}
          className="mt-14 mb-5 font-display text-2xl italic leading-snug tracking-tight sm:text-3xl"
        >
          {line.slice(3)}
        </h2>
      );
      i++;
      continue;
    }

    // Code block
    if (line.startsWith("```")) {
      const lang = line.slice(3).trim();
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) {
        codeLines.push(lines[i]);
        i++;
      }
      i++; // skip closing ```
      blocks.push(
        <div key={key++} className="my-6 overflow-hidden rounded-lg border border-line-strong bg-panel">
          {lang && (
            <div className="border-b border-line px-4 py-2 font-mono text-[10px] uppercase tracking-[0.14em] text-muted">
              {lang}
            </div>
          )}
          <pre className="overflow-x-auto p-4 font-mono text-[12.5px] leading-6 text-secondary">
            <code>{codeLines.join("\n")}</code>
          </pre>
        </div>
      );
      continue;
    }

    // Empty line
    if (line.trim() === "") {
      i++;
      continue;
    }

    // Paragraph — collect consecutive non-empty, non-special lines
    const paraLines: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !lines[i].startsWith("## ") &&
      !lines[i].startsWith("```")
    ) {
      paraLines.push(lines[i]);
      i++;
    }

    const text = paraLines.join(" ");
    blocks.push(
      <p key={key++} className="my-5 text-[15.5px] leading-[1.85] text-secondary">
        {renderInline(text)}
      </p>
    );
  }

  return blocks;
}

function renderInline(text: string): React.ReactNode[] {
  const parts: React.ReactNode[] = [];
  const regex = /`([^`]+)`/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  let key = 0;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }
    parts.push(
      <code
        key={key++}
        className="rounded border border-line bg-panel px-1.5 py-0.5 font-mono text-[13px] text-ink"
      >
        {match[1]}
      </code>
    );
    lastIndex = regex.lastIndex;
  }

  if (lastIndex < text.length) {
    parts.push(text.slice(lastIndex));
  }

  return parts;
}

export default async function BlogPostPage({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const post = getPost(slug);
  if (!post) notFound();

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
            <Link href="/blog" className="text-muted transition-colors hover:text-ink">
              Blog
            </Link>
          </div>

          <div className="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.12em] text-muted">
            <Link href="/docs/overview" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Docs
            </Link>
            <Link href="/blog" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              Blog
            </Link>
            <Link href="https://github.com/hudsonkit/vox" target="_blank" rel="noreferrer noopener" className="rounded-md px-3 py-2 transition-colors hover:bg-wave hover:text-ink">
              GitHub
            </Link>
          </div>
        </div>
      </header>

      <article className="px-6 pb-20 pt-16 sm:px-8 lg:px-12">
        <div className="mx-auto max-w-[680px]">
          <Link
            href="/blog"
            className="inline-flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.12em] text-muted transition-colors hover:text-ink"
          >
            <ArrowLeft className="h-3 w-3" />
            All posts
          </Link>

          <time className="mt-8 block font-mono text-[11px] uppercase tracking-[0.14em] text-muted">
            {formatDate(post.date)}
          </time>

          <h1 className="mt-3 font-display text-3xl leading-[1.15] tracking-[-0.03em] sm:text-[2.75rem]">
            {post.title}
          </h1>

          <div className="mt-10 border-t border-line pt-10">
            {renderContent(post.content)}
          </div>
        </div>
      </article>

      <footer className="px-6 pb-28 pt-14 sm:px-8 lg:px-12">
        <div className="mx-auto flex max-w-[680px] flex-col gap-6 border-t border-line pt-5 sm:flex-row sm:items-end sm:justify-between">
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
