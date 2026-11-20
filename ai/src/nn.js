/// A small neural network (MLP, pure JS, no dependencies) that scores risk 0-100 from the SAME computed
/// features the LLM sees. Deterministic: same features + same weights file = same score, on any machine,
/// so a verdict that used it can be replayed (see replay.js). The weights live in ai/model/mlp.json together
/// with how they were trained (simulated pool episodes, see train/), and are identified by a sha256.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_MODEL_PATH = path.join(here, "..", "model", "mlp.json");

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

export const INPUT_NAMES = [
  "currentDrawdown/30", "maxDrawdown/30", "changePct/30", "swapCount/10", "sellShare",
  "maxDropImpact/20", "lastSwapImpact/20", "secondsSinceLastSwap/300", "recoveredFraction",
];

/// Scale the feature object to the network's 9 inputs (all roughly in [-2, 2]).
export function featureVector(f) {
  const swaps = f.swapCount || 0;
  const maxDd = f.maxDrawdownPct || 0;
  const curDd = f.currentDrawdownPct || 0;
  return [
    clamp(curDd / 30, 0, 2),
    clamp(maxDd / 30, 0, 2),
    clamp((f.changePct || 0) / 30, -2, 2),
    Math.min(swaps, 10) / 10,
    swaps ? (f.sellCount || 0) / swaps : 0,
    clamp((f.maxDropImpactPct || 0) / 20, 0, 2),
    clamp((f.lastSwapImpactPct || 0) / 20, -2, 2),
    Math.min(f.secondsSinceLastSwap ?? 300, 300) / 300,
    maxDd > 0 ? clamp((maxDd - curDd) / maxDd, 0, 1) : 0,
  ];
}

/// layers: [{ w: [out][in], b: [out], act: "relu" | "sigmoid" }, ...]
export function forward(model, x) {
  let a = x;
  for (const L of model.layers) {
    const out = new Array(L.b.length);
    for (let j = 0; j < out.length; j++) {
      let s = L.b[j];
      const row = L.w[j];
      for (let i = 0; i < row.length; i++) s += row[i] * a[i];
      out[j] = L.act === "relu" ? (s > 0 ? s : 0) : 1 / (1 + Math.exp(-s));
    }
    a = out;
  }
  return a[0];
}

export function predict(model, features) {
  const raw = forward(model, featureVector(features));
  return { score: clamp(Math.round(raw * 100), 0, 100), raw };
}

/// Identifies the weights (not the training metadata): put in logs so a verdict names the exact network.
export function modelHash(model) {
  return crypto.createHash("sha256").update(JSON.stringify({ inputs: model.inputs, layers: model.layers })).digest("hex");
}

export function loadModel(file = DEFAULT_MODEL_PATH) {
  const model = JSON.parse(fs.readFileSync(file, "utf8"));
  if (JSON.stringify(model.inputs) !== JSON.stringify(INPUT_NAMES)) throw new Error("model inputs do not match featureVector()");
  return model;
}
