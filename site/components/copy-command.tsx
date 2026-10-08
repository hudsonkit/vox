"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";

async function copyText(value: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(value);
      return true;
    } catch {}
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.readOnly = true;
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  const copied = document.execCommand("copy");
  textarea.remove();
  return copied;
}

export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    setCopied(await copyText(command));
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <button
      onClick={copy}
      className="group inline-flex h-10 max-w-full items-center gap-3 rounded-none border border-line-strong bg-panel px-4 font-mono text-[12px] text-ink transition-colors hover:border-ink/30"
    >
      <span className="text-muted">$</span>
      <span className="min-w-0 truncate">{command}</span>
      <span className="shrink-0 text-muted transition-colors group-hover:text-ink">
        {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
      </span>
    </button>
  );
}

export function CopyCommandBlock({ command, label }: { command: string; label: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    setCopied(await copyText(command));
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="grid gap-3 border border-line bg-canvas px-4 py-4 sm:grid-cols-[minmax(0,390px)_1fr] sm:items-center">
      <button
        onClick={copy}
        className="group flex items-center justify-between rounded-none border border-line-strong bg-panel px-4 py-3 font-mono text-[12px] text-ink transition-colors hover:border-ink/30"
      >
        <span className="min-w-0 truncate text-left">
          <span className="text-muted">$ </span>
          {command}
        </span>
        <span className="ml-3 shrink-0 text-muted transition-colors group-hover:text-ink">
          {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
        </span>
      </button>
      <p className="text-sm leading-7 text-secondary">{label}</p>
    </div>
  );
}

export function CopyPrompt({ prompt, label }: { prompt: string; label: string }) {
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    setCopied(await copyText(prompt));
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="border border-line-strong bg-canvas">
      <div className="flex items-center justify-between border-b border-line px-4 py-2.5">
        <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-muted">{label}</span>
        <button
          onClick={copy}
          aria-label={copied ? "Copied" : `Copy ${label}`}
          className="inline-flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.12em] text-muted transition-colors hover:text-ink"
        >
          {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <p className="whitespace-pre-wrap break-words px-4 py-4 font-mono text-[12px] leading-6 text-ink">{prompt}</p>
    </div>
  );
}
