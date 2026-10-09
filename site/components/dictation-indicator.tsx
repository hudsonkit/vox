"use client";

import { useEffect, useRef } from "react";

const AMBER = [232, 154, 60] as const;
const IDLE_SECONDS = 0.9;
const LISTEN_SECONDS = 6.4;
const COLLAPSE_SECONDS = 0.35;
const DOT_SECONDS = 0.9;
const PASTED_SECONDS = 2.6;
const LISTEN_END = IDLE_SECONDS + LISTEN_SECONDS;
const COLLAPSE_END = LISTEN_END + COLLAPSE_SECONDS;
const DOT_END = COLLAPSE_END + DOT_SECONDS;
const CYCLE_SECONDS = DOT_END + PASTED_SECONDS;
const PITCH = 2.6;
const DOT = 1.15;
const GRID = 0.03;
const HALO = 0.16;
const FADE = 0.12;
const PHRASE = "okay so the words land as you say them and when I stop it pastes right where the cursor is".split(" ");
// The final pass returns the whole take, punctuated, even when the preview lags.
const FINAL = "Okay, so the words land as you say them, and when I stop it pastes right where the cursor is.";
const WORD_SECONDS = 0.5;

// Deterministic 0..1 noise per integer seed.
function hash(n: number) {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}

function isSpoken(word: number) {
  return hash(word) > 0.18;
}

// Speech-like level: syllable pulses inside words, with pauses between words.
function speechLevel(t: number) {
  const word = Math.floor(t / WORD_SECONDS);
  const speaking = isSpoken(word) ? 1 : 0;
  const loudness = 0.4 + hash(word + 91) * 0.6;
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
  return Math.min(count, PHRASE.length);
}

function formatHundredths(seconds: number) {
  const hundredths = Math.max(0, Math.floor(seconds * 100));
  const minutes = Math.floor(hundredths / 6000);
  const secs = Math.floor(hundredths / 100) % 60;
  return `${minutes}:${String(secs).padStart(2, "0")}.${String(hundredths % 100).padStart(2, "0")}`;
}

/**
 * The Minivox recording notch, drawn in the browser. It hangs from a menu
 * bar like the real one: REC and the clock in the wings beside the camera,
 * cancel, the dot-matrix meter and stop below, and the words streaming in
 * left to right. On stop it draws into a dot and the text lands at the cursor.
 */
export function DictationIndicator() {
  const rootRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const timerRef = useRef<HTMLSpanElement>(null);
  const glowRef = useRef<HTMLDivElement>(null);
  const rowRef = useRef<HTMLDivElement>(null);
  const stripRef = useRef<HTMLDivElement>(null);
  const pastedRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const root = rootRef.current;
    const canvas = canvasRef.current;
    const timer = timerRef.current;
    const glow = glowRef.current;
    const row = rowRef.current;
    const strip = stripRef.current;
    const pasted = pastedRef.current;
    if (!root || !canvas || !timer || !glow || !row || !strip || !pasted) return;
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
    let level = 0;
    let warmth = 0;
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
        const value = has ? history[history.length - 1 - column] * half : 0;
        // The tip dot lights by the remainder, so the level moves smoothly.
        const whole = has ? Math.floor(value) : -1;
        const tip = has ? value - whole : 0;
        const strength = 0.92 - (column / Math.max(columns, 1)) * 0.65;
        const x = snap(width - (column + 1) * PITCH);
        // Both ends fade out, so the meter runs to the edges without a hard stop.
        const ends = Math.min(1, x / fade, (width - x) / fade);
        if (ends <= 0) continue;
        for (let r = 0; r < rows; r++) {
          const distance = Math.abs(r - half);
          const lit = distance <= whole ? 1 : distance === whole + 1 ? tip : 0;
          if (lit > 0) {
            const falloff = 1 - (0.55 * distance) / (whole + 2);
            context.fillStyle = `rgba(${AMBER[0]}, ${AMBER[1]}, ${AMBER[2]}, ${strength * falloff * ends * lit})`;
          } else {
            // Unlit dots nearly vanish, with a faint halo just past the lit ones.
            const halo = has ? HALO * strength * Math.max(0, 1 - (distance - whole - 1) / 2) : 0;
            context.fillStyle = `rgba(255, 255, 255, ${(GRID + halo) * ends})`;
          }
          context.fillRect(x, snap(top + r * PITCH), DOT, DOT);
        }
      }
      context.restore();

      if (dot > 0) {
        const grow = dot <= 1 ? 0.4 + dot * 0.6 : 1 - (dot - 1) * 0.5;
        const alpha = dot <= 1 ? dot : 2 - dot;
        context.fillStyle = `rgba(${AMBER[0]}, ${AMBER[1]}, ${AMBER[2]}, ${alpha})`;
        context.beginPath();
        context.arc(width / 2, height / 2, 2 * grow, 0, Math.PI * 2);
        context.fill();
      }
    };

    // Words fill in from the left; once the row is full the strip glides left.
    let shownWords = 0;
    const showWords = (count: number) => {
      if (count === shownWords) return;
      if (count < shownWords) {
        strip.replaceChildren();
        shownWords = 0;
      }
      for (let index = shownWords; index < count; index++) {
        const span = document.createElement("span");
        span.textContent = PHRASE[index];
        span.className = "vox-word";
        strip.append(span);
      }
      shownWords = count;
      const spans = [...strip.children] as HTMLElement[];
      spans.forEach((span, index) => {
        const age = spans.length - 1 - index;
        span.style.opacity = String(age === 0 ? 1 : Math.max(0.3, 0.78 - age * 0.045));
      });
      const overflow = Math.max(0, strip.scrollWidth - row.clientWidth);
      strip.style.transform = `translateX(${-overflow}px)`;
      row.dataset.overflow = overflow > 0 ? "true" : "false";
    };

    let phase = "";
    const setPhase = (next: string) => {
      if (next === phase) return;
      phase = next;
      root.dataset.phase = next;
    };

    const stepLevel = (t: number) => {
      const shaped = Math.max(0, Math.min(1, (Math.pow(speechLevel(t), 0.5) - 0.06) / 0.7));
      level += (shaped - level) * (shaped > level ? 0.85 : 0.35);
      const floor = 0.04 + Math.random() * 0.07;
      history.push(Math.max(level, floor));
      if (history.length > 400) history.shift();
      warmth += (level - warmth) * (level > warmth ? 0.3 : 0.1);
      glow.style.opacity = String(0.06 + warmth * 0.6);
    };

    if (reduceMotion) {
      for (let i = 0; i < 260; i++) stepLevel(1 + i / 60);
      setPhase("listening");
      timer.textContent = "0:04.12";
      showWords(9);
      draw(0, 0);
      return () => observer.disconnect();
    }

    const tick = (now: number) => {
      const t = (now - start) / 1000;

      if (t < IDLE_SECONDS) {
        setPhase("idle");
        draw(0, 0);
      } else if (t < LISTEN_END) {
        const heard = t - IDLE_SECONDS;
        setPhase(heard < 0.9 ? "opening" : "listening");
        stepLevel(heard);
        timer.textContent = formatHundredths(heard);
        if (heard >= 0.9) showWords(wordsHeard(heard - 0.6));
        draw(0, 0);
      } else if (t < COLLAPSE_END) {
        setPhase("collapsing");
        const p = (t - LISTEN_END) / COLLAPSE_SECONDS;
        glow.style.opacity = "0";
        draw(p * p, 0);
      } else if (t < DOT_END) {
        const p = (t - COLLAPSE_END) / DOT_SECONDS;
        draw(1, p < 0.25 ? p / 0.25 : 1 + (p - 0.25) / 0.75);
        if (p > 0.55) {
          setPhase("pasted");
          pasted.textContent = FINAL;
        }
      } else if (t < CYCLE_SECONDS) {
        setPhase("pasted");
        draw(1, 0);
      } else {
        history = [];
        level = 0;
        warmth = 0;
        showWords(0);
        pasted.textContent = "";
        timer.textContent = formatHundredths(0);
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

  const control = "grid h-[15px] w-[15px] shrink-0 place-items-center rounded-full border-[0.5px] border-white/[0.14] bg-[linear-gradient(180deg,rgba(255,255,255,0.09),rgba(255,255,255,0.02))]";

  return (
    <figure className="vox-notch-demo mx-auto w-full max-w-[520px]" aria-label="Minivox recording notch">
      <div
        ref={rootRef}
        data-phase="idle"
        className="relative overflow-hidden rounded-[10px] border border-line bg-[linear-gradient(180deg,#121212,#0b0b0b)]"
      >
        {/* Menu bar with the camera housing in the middle. */}
        <div className="relative flex h-[26px] items-center justify-between border-b border-white/[0.04] bg-white/[0.03] px-3" aria-hidden="true">
          <div className="flex items-center gap-2.5">
            <span className="h-[7px] w-[7px] rounded-full bg-white/25" />
            <span className="h-[3px] w-8 rounded-full bg-white/[0.12]" />
            <span className="hidden h-[3px] w-6 rounded-full bg-white/[0.09] sm:block" />
          </div>
          <div className="flex items-center gap-2.5">
            <span className="h-[3px] w-5 rounded-full bg-white/[0.09]" />
            <span className="h-[3px] w-9 rounded-full bg-white/[0.12]" />
          </div>
        </div>

        {/* The notch. */}
        <div className="vox-notch absolute left-1/2 top-0 -translate-x-1/2" aria-hidden="true">
          <div className="vox-notch-surface absolute inset-0" />
          <div ref={glowRef} className="vox-notch-glow absolute inset-0 opacity-0" />
          <div className="vox-notch-content relative flex h-full flex-col">
            <div className="flex h-[26px] items-end justify-between pb-[2px] pl-[13.5px] pr-[12px]">
              <span className="flex items-center gap-1 font-mono text-[9px] font-light tracking-[0.09em] text-[#ff453a]/85">
                <span className="h-1 w-1 rounded-full bg-[#ff453a] shadow-[0_0_5px_#ff453a]" />
                REC
              </span>
              <span ref={timerRef} className="font-mono text-[10px] font-light tabular-nums text-white/70">0:00.00</span>
            </div>
            <div className="flex h-[21px] items-center gap-1.5 px-[10px]">
              <span className={control}>
                <svg width="4" height="4" viewBox="0 0 4 4" fill="none" stroke="rgba(255,255,255,0.55)" strokeWidth="0.6" strokeLinecap="round">
                  <path d="M0.5 0.5l3 3M3.5 0.5l-3 3" />
                </svg>
              </span>
              <canvas ref={canvasRef} className="h-4 min-w-0 flex-1" />
              <span className={control}>
                <span className="h-1 w-1 rounded-[0.75px] bg-[#e89a3c]/70" />
              </span>
            </div>
            <div ref={rowRef} data-overflow="false" className="vox-words-row mx-[13px] h-[20px] overflow-hidden">
              <div ref={stripRef} className="vox-words-strip flex h-full w-max items-center gap-[0.32em] whitespace-nowrap text-[12px] font-light text-white" />
            </div>
          </div>
        </div>

        {/* A document with the cursor where the text lands. */}
        <div className="px-6 pb-8 pt-[96px] sm:px-10" aria-hidden="true">
          <div className="space-y-2.5">
            <span className="block h-[5px] w-24 rounded-full bg-white/[0.1]" />
            <span className="block h-[5px] w-[82%] rounded-full bg-white/[0.06]" />
            <span className="block h-[5px] w-[64%] rounded-full bg-white/[0.06]" />
          </div>
          <p className="mt-5 min-h-[44px] text-[13px] font-light leading-[22px] text-white/80">
            <span ref={pastedRef} className="vox-pasted" />
            <span className="vox-caret ml-px inline-block h-[15px] w-px translate-y-[3px] bg-accent" />
          </p>
        </div>
      </div>
      <figcaption className="mt-4 text-center font-mono text-[10px] uppercase tracking-[0.14em] text-muted">
        Right ⌘M to start · again to paste
      </figcaption>
    </figure>
  );
}
