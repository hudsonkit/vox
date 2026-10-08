"use client";

import { useEffect, useRef } from "react";

const AMBER = [232, 154, 60] as const;
const LISTEN_SECONDS = 6;
const COLLAPSE_SECONDS = 0.35;
const DOT_SECONDS = 0.9;
const CYCLE_SECONDS = LISTEN_SECONDS + COLLAPSE_SECONDS + DOT_SECONDS + 0.4;
const PITCH = 2.5;
const DOT = 1;

// Deterministic 0..1 noise per integer seed.
function hash(n: number) {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}

// Speech-like level: syllable pulses inside words, with pauses between words.
function speechLevel(t: number) {
  const word = Math.floor(t / 0.62);
  const speaking = hash(word) > 0.22 ? 1 : 0;
  const loudness = 0.45 + hash(word + 91) * 0.55;
  const syllable = Math.max(0, Math.sin(t * Math.PI * 2 * (3.6 + hash(word + 7) * 1.6)));
  const grain = 0.75 + hash(Math.floor(t * 60)) * 0.25;
  return Math.min(1, speaking * loudness * Math.pow(syllable, 1.4) * grain);
}

/**
 * The Minivox recording notch, drawn in the browser: REC, a scrolling
 * dot-matrix meter, a tenths timer, and the collapse-to-dot finish.
 */
export function DictationIndicator() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const timerRef = useRef<HTMLSpanElement>(null);
  const wingsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const timer = timerRef.current;
    const wings = wingsRef.current;
    if (!canvas || !timer || !wings) return;
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

      for (let column = 0; column < columns; column++) {
        const has = column < history.length;
        const level = has ? history[history.length - 1 - column] : 0;
        const lit = has ? Math.round(level * half) : -1;
        const age = column / Math.max(columns, 1);
        const x = snap(width - (column + 1) * PITCH);
        for (let row = 0; row < rows; row++) {
          const distance = Math.abs(row - half);
          const falloff = 1 - (0.55 * distance) / (lit + 1);
          context.fillStyle = distance <= lit
            ? `rgba(${AMBER[0]}, ${AMBER[1]}, ${AMBER[2]}, ${(0.9 - age * 0.7) * falloff})`
            : "rgba(255, 255, 255, 0.06)";
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

    if (reduceMotion) {
      for (let i = 0; i < 200; i++) {
        const previous = history.at(-1) ?? 0;
        const shaped = Math.pow(speechLevel(1 + i / 60), 0.45);
        history.push(Math.max(previous + (shaped - previous) * (shaped > previous ? 0.65 : 0.09), 0.14));
      }
      timer.textContent = "0:03.4";
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
        draw(0, 0);
      } else if (t < LISTEN_SECONDS + COLLAPSE_SECONDS) {
        const p = (t - LISTEN_SECONDS) / COLLAPSE_SECONDS;
        wings.style.opacity = String(1 - p);
        draw(p * p, 0);
      } else if (t < LISTEN_SECONDS + COLLAPSE_SECONDS + DOT_SECONDS) {
        const p = (t - LISTEN_SECONDS - COLLAPSE_SECONDS) / DOT_SECONDS;
        wings.style.opacity = "0";
        draw(1, p < 0.25 ? p / 0.25 : 1 + (p - 0.25) / 0.75);
      } else if (t < CYCLE_SECONDS) {
        draw(1, 0);
      } else {
        history = [];
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

  return (
    <figure className="mx-auto w-full max-w-[320px]" aria-label="Minivox recording indicator">
      <div className="mx-auto w-[92%] overflow-hidden rounded-[16px] bg-black ring-1 ring-white/[0.06] shadow-[0_12px_32px_rgba(0,0,0,0.4)]">
        <div ref={wingsRef} className="flex h-6 items-center px-2.5 font-mono text-[9px] font-extralight tracking-[0.04em]">
          <span className="flex flex-1 items-center gap-1.5 text-[#ff453a]/80">
            <span aria-hidden="true" className="h-1 w-1 rounded-full bg-[#ff453a]" />
            REC
          </span>
          <span ref={timerRef} className="flex-1 text-right tabular-nums text-white/70">
            0:00.0
          </span>
        </div>
        <div className="flex h-6 items-center gap-2.5 px-2.5 pb-1.5">
          <span aria-hidden="true" className="grid h-3.5 w-3.5 shrink-0 place-items-center rounded-full border-[0.5px] border-white/[0.12] text-[6px] leading-none text-white/55">
            ✕
          </span>
          <canvas ref={canvasRef} aria-hidden="true" className="h-full min-w-0 flex-1" />
          <span aria-hidden="true" className="grid h-3.5 w-3.5 shrink-0 place-items-center rounded-full border-[0.5px] border-white/[0.12]">
            <span className="h-[5px] w-[5px] rounded-[1px] bg-[#e89a3c]/70" />
          </span>
        </div>
      </div>
      <div className="h-5" aria-hidden="true" />
      <figcaption className="text-center font-mono text-[10px] uppercase tracking-[0.14em] text-muted">
        Right ⌘M to start · again to stop
      </figcaption>
    </figure>
  );
}
