/// Simulated episodes on a constant-product pool shaped like MockPool (price = stable/vol, no fee).
/// Episode kinds: calm, noisy, V-shaped crash with recovery, crash without recovery, single dump, pump.
/// Features come from the real computeFeatures() so training inputs have the service's exact distribution.
import { computeFeatures } from "../src/features.js";

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const RV = 10000; // vol reserve: ~1000 VOL sold moves the price ~17%, as in the demo pool
const RS = 10000;

class Pool {
  constructor() { this.v = RV; this.s = RS; this.k = RV * RS; }
  get price() { return this.s / this.v; }
  sell(dv) { this.v += dv; this.s = this.k / this.v; }
  buy(ds) { this.s += ds; this.v = this.k / this.s; }
  /// stable needed to bring the price up to `target`
  buyToPrice(target) { return Math.max(0, Math.sqrt(this.k * target) - this.s); }
}

export const KINDS = ["calm", "noisy", "crash_v", "crash_down", "single_dump", "pump"];

export function makeEpisode(rng, kind, duration = 900) {
  const pool = new Pool();
  const ev = [];
  const U = (a, b) => a + (b - a) * rng();
  const doSell = (t, dv) => { pool.sell(dv); ev.push({ ts: t, price: pool.price, kind: "swap", sellVol: true, amountIn: dv }); };
  const doBuy = (t, ds) => { pool.buy(ds); ev.push({ ts: t, price: pool.price, kind: "swap", sellVol: false, amountIn: ds }); };
  const noise = (from, to, gap = [15, 90], size = [20, 400]) => {
    for (let t = from + U(...gap); t < to; t += U(...gap)) (rng() < 0.5 ? doSell : doBuy)(t, U(...size));
  };
  const crash = (t0) => {
    const n = 2 + Math.floor(rng() * 5);
    let t = t0;
    for (let i = 0; i < n; i++) { doSell(t, U(600, 1500)); t += U(8, 14); }
    return t;
  };

  if (kind === "calm") {
    noise(0, duration, [30, 120], [20, 250]);
  } else if (kind === "noisy") {
    noise(0, duration, [10, 45], [50, 900]);
  } else if (kind === "crash_v") {
    const t0 = U(40, 200);
    noise(0, t0, [20, 80], [20, 300]);
    const pre = pool.price;
    let t = crash(t0) + U(20, 150);
    const nb = 1 + Math.floor(rng() * 3);
    const target = pre * U(0.9, 1.02);
    for (let i = 1; i <= nb; i++) {
      const stepTarget = pool.price + (target - pool.price) * (i / nb);
      doBuy(t, pool.buyToPrice(stepTarget));
      t += U(5, 20);
    }
    noise(t, duration, [20, 90], [20, 300]);
  } else if (kind === "crash_down") {
    const t0 = U(40, 200);
    noise(0, t0, [20, 80], [20, 300]);
    let t = crash(t0);
    if (rng() < 0.6) { for (; t < duration; t += U(10, 40)) doSell(t, U(100, 600)); }
    else noise(t, duration, [40, 150], [10, 150]);
  } else if (kind === "single_dump") {
    const t0 = U(40, 300);
    noise(0, t0, [20, 80], [20, 300]);
    doSell(t0, U(800, 2500));
    noise(t0, duration, [30, 120], [20, 250]);
  } else if (kind === "pump") {
    const t0 = U(40, 300);
    noise(0, t0, [20, 80], [20, 300]);
    let t = t0;
    for (let i = 0, n = 1 + Math.floor(rng() * 4); i < n; i++) { doBuy(t, U(800, 2500)); t += U(8, 20); }
    if (rng() < 0.5) { t += U(20, 100); for (let i = 0; i < 3; i++) { doSell(t, U(500, 1500)); t += U(8, 20); } }
    noise(t, duration, [30, 120], [20, 300]);
  } else throw new Error(`unknown episode kind ${kind}`);

  ev.sort((a, b) => a.ts - b.ts);
  return { kind, duration, samples: [{ ts: 0, price: 1, kind: "seed" }, ...ev] };
}

function priceAt(samples, t) {
  let p = samples[0].price;
  for (const s of samples) { if (s.ts <= t) p = s.price; else break; }
  return p;
}

/// Label: how dangerous it is to hold VOL right now = 4 x (worst further fall in the next 120 s) + 3 x (fall in the last 30 s), 0..100.
/// It is forward-looking on purpose, so a recovered market labels low even though the crash is still inside the 300 s window.
export function label(samples, t, duration) {
  const p = priceAt(samples, t);
  let low = p;
  for (const s of samples) if (s.ts > t && s.ts <= Math.min(t + 120, duration)) low = Math.min(low, s.price);
  const future = Math.max(0, ((p - low) / p) * 100);
  const back = priceAt(samples, t - 30);
  const recent = Math.max(0, ((back - p) / back) * 100);
  return Math.min(100, Math.max(0, Math.round(4 * future + 3 * recent)));
}

export function buildDataset(episodes, step = 5, windowSec = 300) {
  const rows = [];
  for (const ep of episodes) {
    for (let t = 30; t <= ep.duration; t += step) {
      const seen = ep.samples.filter((s) => s.ts <= t);
      const f = computeFeatures(seen, t, windowSec);
      // The service never asks the model about a window with no swaps (scoring.js "quiet" rule), so don't train on those:
      // their labels only reflect whether a crash happens to start soon, which no feature can predict.
      if (f.swapCount === 0) continue;
      rows.push({ f, y: label(ep.samples, t, ep.duration), kind: ep.kind });
    }
  }
  return rows;
}

export function makeEpisodes(rng, count, mix = { calm: 0.2, noisy: 0.12, crash_v: 0.26, crash_down: 0.18, single_dump: 0.12, pump: 0.12 }) {
  const kinds = Object.keys(mix);
  const out = [];
  for (let i = 0; i < count; i++) {
    let r = rng(), k = kinds[kinds.length - 1];
    for (const name of kinds) { if (r < mix[name]) { k = name; break; } r -= mix[name]; }
    out.push(makeEpisode(rng, k));
  }
  return out;
}
