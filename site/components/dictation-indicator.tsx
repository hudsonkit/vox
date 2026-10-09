"use client";

import { useEffect, useRef } from "react";

const AMBER = [232, 154, 60] as const;
const LISTEN_SECONDS = 6;
const COLLAPSE_SECONDS = 0.35;
const DOT_SECONDS = 0.9;
const CYCLE_SECONDS = LISTEN_SECONDS + COLLAPSE_SECONDS + DOT_SECONDS + 0.4;
const PITCH = 2.5;
const DOT = 1;
const GRID = 0.03;
const HALO = 0.16;
const FADE = 0.16;
const PHRASE = "okay so the words land as you say them then it pastes where your cursor is".split(" ");
const WORD_SECONDS = 0.62;

// Deterministic 0..1 noise per integer seed.
function hash(n: number) {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}

function isSpoken(word: number) {
  return hash(word) > 0.22;
}

// Speech-like level: syllable pulses inside words, with pauses between words.
function speechLevel(t: number) {
  const word = Math.floor(t / WORD_SECONDS);
  const speaking = isSpoken(word) ? 1 : 0;
  const loudness = 0.45 + hash(word + 91) * 0.55;
  const syllable = Math.max(0, Math.sin(t * Math.PI * 2 * (3.6 + hash(word + 7) * 1.6)));
  const grain = 0.75 + hash(Math.floor(t * 60)) * 0.25;
  return Math.min(1, speaking * loudness * Math.pow(syllable, 1.4) * grain);
}

// Words heard by time t: one per spoken stretch of the level signal.
function wordsHeard(t: number) {
  let count = 0;
  for (let word = 0; word <= Math.floor(t / WORD_SECONDS) - 1; word++) {
    if (isSpoken(word)) count++;
  }
  return PHRASE.slice(0, Math.min(count, PHRASE.length));
}

/**
 * The Minivox recording notch, drawn in the browser: a thin dot-matrix
 * meter with cancel, clock and stop laid over it, the words streaming in
 * underneath, and the collapse-to-dot finish.
 */
export function DictationIndicator() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const timerRef = useRef<HTMLSpanElement>(null);
  const wingsRef = useRef<HTMLDivElement>(null);
  const wordsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const timer = timerRef.current;
    const wings = wingsRef.current;
    const line = wordsRef.current;
    if (!canvas || !timer || !wings || !line) return;
    const context = canvas.getContext("2d");
    if (!context) return;

    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let width = 0;
    let height = 0;
    let ratio = 1;

    const resize = () => {
      ratio = window.devicePixelRatio || 1;
      width = canvas.clientWidth;
      height = canvas.clientHeight;
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
    };
    resize();
    const observer = new ResizeObserver(resize);
    observer.observe(canvas);

    let history: number[] = [];
    let start = performance.now();
    let frame = 0;

    const draw = (collapse: number, dot: number) => {
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      context.clearRect(0, 0, width, height);
      const snap = (v: number) => Math.round(v * ratio) / ratio;

      let rows = Math.floor(height / PITCH);
      if (rows % 2 === 0) rows -= 1;
      const half = (rows - 1) / 2;
      const columns = Math.floor(width / PITCH);
      const top = snap((height - rows * PITCH) / 2);

      context.save();
      const scale = Math.max(0.001, 1 - collapse);
      context.translate(width / 2, 0);
      context.scale(scale, 1);
      context.translate(-width / 2, 0);
      context.globalAlpha = 1 - collapse;

      const fade = width * FADE;
      for (let column = 0; column < columns; column++) {
        const has = column < history.length;
        const level = has ? history[history.length - 1 - column] : 0;
        const lit = has ? Math.round(level * half) : -1;
        const strength = 0.9 - (column / Math.max(columns, 1)) * 0.7;
        const x = snap(width - (column + 1) * PITCH);
        // Both ends fade out, so the meter runs to the edges without a hard stop.
        const ends = Math.min(1, x / fade, (width - x) / fade);
        if (ends <= 0) continue;
        for (let row = 0; row < rows; row++) {
          const distance = Math.abs(row - half);
          if (distance <= lit) {
            const falloff = 1 - (0.55 * distance) / (lit + 1);
            context.fillStyle = `rgba(${AMBER[0]}, ${AMBER[1]}, ${AMBER[2]}, ${strength * falloff * ends})`;
          } else {
            // Unlit dots nearly vanish, with a faint halo just past the lit ones.
            const glow = has ? HALO * strength * Math.max(0, 1 - (distance - lit - 1) / 2) : 0;
            context.fillStyle = `rgba(255, 255, 255, ${(GRID + glow) * ends})`;
          }
          context.fillRect(x, snap(top + row * PITCH), DOT, DOT);
        }
      }
      context.restore();

      if (dot > 0) {
        const grow = dot <= 1 ? 0.4 + dot * 0.6 : 1 - (dot - 1) * 0.5;
        const alpha = dot <= 1 ? dot : 2 - dot;
        context.fillStyle = `rgba(${AMBER[0]}, ${AMBER[1]}, ${AMBER[2]}, ${alpha})`;
        context.beginPath();
        context.arc(width / 2, height / 2, 1.75 * grow, 0, Math.PI * 2);
        context.fill();
      }
    };

    const formatTenths = (seconds: number) => {
      const tenths = Math.max(0, Math.floor(seconds * 10));
      const minutes = Math.floor(tenths / 600);
      const secs = Math.floor(tenths / 10) % 60;
      return `${minutes}:${String(secs).padStart(2, "0")}.${tenths % 10}`;
    };

    let shownWords = -1;
    const showWords = (words: string[]) => {
      if (words.length === shownWords) return;
      shownWords = words.length;
      line.replaceChildren(
        ...words.slice(-12).map((word, index, visible) => {
          const age = visible.length - 1 - index;
          const span = document.createElement("span");
          span.textContent = word;
          span.style.opacity = String(age === 0 ? 0.95 : Math.max(0.3, 0.7 - age * 0.06));
          return span;
        }),
      );
    };

    if (reduceMotion) {
      for (let i = 0; i < 200; i++) {
        const previous = history.at(-1) ?? 0;
        const shaped = Math.pow(speechLevel(1 + i / 60), 0.45);
        history.push(Math.max(previous + (shaped - previous) * (shaped > previous ? 0.65 : 0.09), 0.14));
      }
      timer.textContent = "0:03.4";
      showWords(PHRASE.slice(0, 8));
      draw(0, 0);
      return () => observer.disconnect();
    }

    const tick = (now: number) => {
      const t = (now - start) / 1000;

      if (t < LISTEN_SECONDS) {
        const shaped = Math.pow(speechLevel(t), 0.45);
        const previous = history.at(-1) ?? 0;
        const envelope = previous + (shaped - previous) * (shaped > previous ? 0.65 : 0.09);
        history.push(Math.max(envelope, 0.06 + Math.random() * 0.16));
        if (history.length > 240) history.shift();
        timer.textContent = formatTenths(t);
        wings.style.opacity = "1";
        line.style.opacity = "1";
        showWords(wordsHeard(t));
        draw(0, 0);
      } else if (t < LISTEN_SECONDS + COLLAPSE_SECONDS) {
        const p = (t - LISTEN_SECONDS) / COLLAPSE_SECONDS;
        wings.style.opacity = String(1 - p);
        line.style.opacity = String(1 - p);
        draw(p * p, 0);
      } else if (t < LISTEN_SECONDS + COLLAPSE_SECONDS + DOT_SECONDS) {
        const p = (t - LISTEN_SECONDS - COLLAPSE_SECONDS) / DOT_SECONDS;
        wings.style.opacity = "0";
        line.style.opacity = "0";
        draw(1, p < 0.25 ? p / 0.25 : 1 + (p - 0.25) / 0.75);
      } else if (t < CYCLE_SECONDS) {
        draw(1, 0);
      } else {
        history = [];
        showWords([]);
        start = now;
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);

    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
    };
  }, []);

  const control = "pointer-events-none grid h-3 w-3 shrink-0 place-items-center rounded-full border-[0.5px] border-white/[0.1] bg-black/30";

  return (
    <figure className="mx-auto w-full max-w-[248px]" aria-label="Minivox recording indicator">
      <div className="overflow-hidden rounded-[12px] bg-black px-1 pb-1.5 pt-1 ring-[0.5px] ring-white/[0.07] shadow-[0_10px_28px_rgba(0,0,0,0.38)]">
        <div className="relative flex h-[18px] items-center">
          <canvas ref={canvasRef} aria-hidden="true" className="h-[13px] w-full" />
          <div ref={wingsRef} className="absolute inset-x-1.5 flex items-center gap-1.5 font-mono text-[8px] font-extralight tracking-[0.04em]">
            <span aria-hidden="true" className={control}>
              <svg width="4" height="4" viewBox="0 0 4 4" fill="none" stroke="rgba(255,255,255,0.55)" strokeWidth="0.6" strokeLinecap="round">
                <path d="M0.5 0.5l3 3M3.5 0.5l-3 3" />
              </svg>
            </span>
            <span className="flex items-center gap-1 text-white/65 [text-shadow:0_0_4px_#000]">
              <span aria-hidden="true" className="h-[3px] w-[3px] rounded-full bg-[#ff453a]" />
              <span ref={timerRef} className="tabular-nums">0:00.0</span>
            </span>
            <span className="flex-1" />
            <span aria-hidden="true" className={control}>
              <span className="h-[3.5px] w-[3.5px] rounded-[0.5px] bg-[#e89a3c]/70" />
            </span>
          </div>
        </div>
        <div
          ref={wordsRef}
          aria-hidden="true"
          className="flex h-3.5 items-center justify-end gap-[0.5em] overflow-hidden whitespace-nowrap px-2 font-mono text-[8.5px] font-extralight text-white [mask-image:linear-gradient(90deg,transparent,#000_30%)]"
        />
      </div>
      <div className="h-4" aria-hidden="true" />
      <figcaption className="text-center font-mono text-[9px] uppercase tracking-[0.14em] text-muted">
        Right ⌘M to start · again to stop
      </figcaption>
    </figure>
  );
}
