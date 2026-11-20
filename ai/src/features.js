/// Pure functions: turn raw pool swaps into numbers a risk model (or a human) can reason about.
///
/// A "sample" is one point on the pool price path:
///   { ts: unix seconds, price: STABLE per VOL, kind: "seed" | "swap",
///     sellVol?: true if VOL was sold, amountIn?: tokens (not wei), block?: number }
/// The first sample is a "seed" (the pool price when the service started) so the first
/// real swap has a price to be compared against.

const r2 = (x) => Math.round(x * 100) / 100;
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

export function computeFeatures(samples, now, windowSec) {
  const start = now - windowSec;
  const before = [...samples].reverse().find((s) => s.ts < start);
  const inWin = samples.filter((s) => s.ts >= start);
  const path = before ? [before, ...inWin] : inWin;

  if (path.length === 0) {
    return {
      windowSec, currentPrice: null, windowStartPrice: null, changePct: 0,
      currentDrawdownPct: 0, maxDrawdownPct: 0, swapCount: 0, sellCount: 0, buyCount: 0,
      sellVolumeVol: 0, buyVolumeStable: 0, maxSwapImpactPct: 0, maxDropImpactPct: 0, lastSwapImpactPct: 0,
      secondsSinceLastSwap: null,
    };
  }

  const cur = path[path.length - 1].price;
  const first = path[0].price;
  let peak = path[0].price;
  let maxDd = 0;
  let maxImpact = 0;
  let maxDrop = 0;
  let lastImpact = 0;
  for (let i = 1; i < path.length; i++) {
    const impact = (path[i].price / path[i - 1].price - 1) * 100;
    if (path[i].kind === "swap") {
      maxImpact = Math.max(maxImpact, Math.abs(impact));
      maxDrop = Math.max(maxDrop, -impact);
      lastImpact = impact;
    }
    peak = Math.max(peak, path[i].price);
    maxDd = Math.max(maxDd, ((peak - path[i].price) / peak) * 100);
  }
  const winPeak = Math.max(...path.map((s) => s.price));

  const swaps = inWin.filter((s) => s.kind === "swap");
  const sells = swaps.filter((s) => s.sellVol);
  const buys = swaps.filter((s) => !s.sellVol);
  const lastSwap = swaps[swaps.length - 1];

  return {
    windowSec,
    currentPrice: r2(cur),
    windowStartPrice: r2(first),
    changePct: r2((cur / first - 1) * 100),
    currentDrawdownPct: r2(Math.max(0, ((winPeak - cur) / winPeak) * 100)),
    maxDrawdownPct: r2(maxDd),
    swapCount: swaps.length,
    sellCount: sells.length,
    buyCount: buys.length,
    sellVolumeVol: r2(sells.reduce((a, s) => a + (s.amountIn || 0), 0)),
    buyVolumeStable: r2(buys.reduce((a, s) => a + (s.amountIn || 0), 0)),
    maxSwapImpactPct: r2(maxImpact),
    maxDropImpactPct: r2(maxDrop),
    lastSwapImpactPct: r2(lastImpact),
    secondsSinceLastSwap: lastSwap ? Math.max(0, Math.round(now - lastSwap.ts)) : null,
  };
}

/// Deterministic rule-based score 0..100. It is the safety rail around the LLM
/// (see applyGuard) and the fallback if the LLM is unreachable.
/// Uses the CURRENT drawdown from the window peak, so the score falls again as price recovers.
export function baselineScore(f) {
  if (f.currentPrice === null) return 0;
  // Only the CURRENT drawdown counts, so a recovered crash stops looking dangerous.
  // Swap-level detail (sell streaks, impact, speed) is left to the LLM.
  const s = 3.5 * f.currentDrawdownPct;
  return clamp(Math.round(s), 0, 100);
}

/// The LLM decides inside a band around the rule score. It cannot invent a crash in a calm
/// market, nor talk the vault out of reacting to an obvious one.
export function applyGuard(llmScore, baseline, band) {
  return clamp(Math.round(llmScore), Math.max(0, baseline - band), Math.min(100, baseline + band));
}

/// NN "asym" mode. One condition drives both helpers below: the rule score is <= calmMax, i.e. the pool price is
/// essentially back at its window peak (calmMax 5 = drawdown <= ~1.4%). In that state a de-risk is impossible anyway
/// (it needs a final score >= 70, i.e. a rule score >= 40), so only a re-risk can be affected.
///
/// mixModelScore: when NOT calm, the NN can only raise the score (max of LLM and NN), so it can never talk the vault
/// out of a de-risk or into an early re-risk during a pause in a crash. When calm, LLM and NN are blended.
export function mixModelScore(llmScore, nnScore, { w = 0.5, mode = "blend", base = 0, calmMax = 5 } = {}) {
  if (nnScore === null || nnScore === undefined) return llmScore;
  if (mode === "asym" && base > calmMax) return Math.max(llmScore, nnScore);
  return Math.round((1 - w) * llmScore + w * nnScore);
}

/// applyGuard, except that when the rule score is calm the final score cannot exceed the re-risk threshold `low`.
/// Without this a stale LLM verdict (85 on a fully recovered pool) is clamped to rule+30 = 31 or 32 and the vault
/// cannot re-risk, which needs <= 30 (seen live: epoch 198).
export function applyGuardCalmCap(score, baseline, band, low, calmMax = 5) {
  const upper = baseline <= calmMax ? Math.min(baseline + band, low) : Math.min(100, baseline + band);
  return clamp(Math.round(score), Math.max(0, baseline - band), upper);
}
