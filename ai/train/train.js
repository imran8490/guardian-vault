/// Trains the risk MLP on simulated pool episodes (see simulate.js) and writes ai/model/mlp.json.
///   node train/train.js            # fixed seeds: the same command gives the same weights file
/// Honest scope: the training data is SIMULATED (constant-product pool, hand-written crash/recovery/pump
/// scenarios, a forward-looking label). It is not market data. Held-out episodes are reported below.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { featureVector, forward, modelHash, INPUT_NAMES } from "../src/nn.js";
import { mulberry32, makeEpisodes, buildDataset, KINDS } from "./simulate.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const OUT = process.argv[2] || path.join(here, "..", "model", "mlp.json");
const SEED = 20261119, TRAIN_EP = 700, TEST_EP = 150, EPOCHS = 60, BATCH = 256, LR = 0.003;
const SIZES = [INPUT_NAMES.length, 12, 6, 1];

const rng = mulberry32(SEED);
const toXY = (rows) => rows.map((r) => ({ x: featureVector(r.f), y: r.y / 100, yRaw: r.y, kind: r.kind }));
const train = toXY(buildDataset(makeEpisodes(rng, TRAIN_EP)));
const test = toXY(buildDataset(makeEpisodes(mulberry32(SEED + 1), TEST_EP)));
console.log(`train samples ${train.length}, held-out samples ${test.length} (${TEST_EP} unseen episodes)`);

// He init, Adam, MSE on a sigmoid output, deterministic shuffling
const gauss = () => Math.sqrt(-2 * Math.log(1 - rng())) * Math.cos(2 * Math.PI * rng());
const layers = [];
for (let l = 0; l < SIZES.length - 1; l++) {
  const [nin, nout] = [SIZES[l], SIZES[l + 1]];
  layers.push({
    w: Array.from({ length: nout }, () => Array.from({ length: nin }, () => gauss() * Math.sqrt(2 / nin))),
    b: new Array(nout).fill(0),
    act: l === SIZES.length - 2 ? "sigmoid" : "relu",
  });
}
const zerosLike = () => layers.map((L) => ({ w: L.w.map((r) => r.map(() => 0)), b: L.b.map(() => 0) }));
let m = zerosLike(), v = zerosLike(), step = 0;

function backprop(x, y, g) {
  const acts = [x], pre = [];
  let a = x;
  for (const L of layers) {
    const z = L.b.map((b, j) => L.w[j].reduce((s, w, i) => s + w * a[i], b));
    pre.push(z);
    a = z.map((s) => (L.act === "relu" ? (s > 0 ? s : 0) : 1 / (1 + Math.exp(-s))));
    acts.push(a);
  }
  const out = a[0];
  let delta = [(out - y) * 2 * out * (1 - out)];
  for (let l = layers.length - 1; l >= 0; l--) {
    const L = layers[l], inp = acts[l];
    const next = new Array(inp.length).fill(0);
    for (let j = 0; j < delta.length; j++) {
      g[l].b[j] += delta[j];
      for (let i = 0; i < inp.length; i++) { g[l].w[j][i] += delta[j] * inp[i]; next[i] += delta[j] * L.w[j][i]; }
    }
    if (l > 0) delta = next.map((d, i) => (pre[l - 1][i] > 0 ? d : 0));
  }
  return (out - y) ** 2;
}

for (let epoch = 1; epoch <= EPOCHS; epoch++) {
  const idx = train.map((_, i) => i);
  for (let i = idx.length - 1; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [idx[i], idx[j]] = [idx[j], idx[i]]; }
  let loss = 0;
  for (let b = 0; b < idx.length; b += BATCH) {
    const g = zerosLike(), batch = idx.slice(b, b + BATCH);
    for (const k of batch) loss += backprop(train[k].x, train[k].y, g);
    step++;
    const c1 = 1 - 0.9 ** step, c2 = 1 - 0.999 ** step;
    layers.forEach((L, l) => {
      for (let j = 0; j < L.b.length; j++) {
        for (const [arr, ga, ma, va, idxs] of [[L.w[j], g[l].w[j], m[l].w[j], v[l].w[j], null]]) {
          for (let i = 0; i < arr.length; i++) {
            const gr = ga[i] / batch.length;
            ma[i] = 0.9 * ma[i] + 0.1 * gr; va[i] = 0.999 * va[i] + 0.001 * gr * gr;
            arr[i] -= LR * (ma[i] / c1) / (Math.sqrt(va[i] / c2) + 1e-8);
          }
        }
        const gr = g[l].b[j] / batch.length;
        m[l].b[j] = 0.9 * m[l].b[j] + 0.1 * gr; v[l].b[j] = 0.999 * v[l].b[j] + 0.001 * gr * gr;
        L.b[j] -= LR * (m[l].b[j] / c1) / (Math.sqrt(v[l].b[j] / c2) + 1e-8);
      }
    });
  }
  if (epoch % 10 === 0 || epoch === 1) console.log(`epoch ${epoch}  train MSE (0-1 scale) ${(loss / train.length).toFixed(5)}`);
}

const model = { version: 1, inputs: INPUT_NAMES, layers };
const evalSet = (set) => {
  const pred = set.map((r) => Math.round(forward(model, r.x) * 100));
  const mae = pred.reduce((s, p, i) => s + Math.abs(p - set[i].yRaw), 0) / set.length;
  const conf = (thr, hi) => {
    let tp = 0, fp = 0, fn = 0, tn = 0;
    pred.forEach((p, i) => { const a = hi ? set[i].yRaw >= thr : set[i].yRaw <= thr, b = hi ? p >= thr : p <= thr; if (a && b) tp++; else if (!a && b) fp++; else if (a && !b) fn++; else tn++; });
    return { thr, hi, agree: (tp + tn) / set.length, tp, fp, fn, tn };
  };
  return { mae, de: conf(70, true), re: conf(30, false), pred };
};
const tr = evalSet(train.slice(0, 20000)), te = evalSet(test);
const byKind = {};
for (const k of KINDS) {
  const sub = test.filter((r) => r.kind === k);
  if (sub.length) byKind[k] = +evalSet(sub).mae.toFixed(2);
}
const holdout = {
  episodes: TEST_EP, samples: test.length, maeScore: +te.mae.toFixed(2),
  deRisk70: { agreement: +te.de.agree.toFixed(4), truePos: te.de.tp, falsePos: te.de.fp, falseNeg: te.de.fn },
  reRisk30: { agreement: +te.re.agree.toFixed(4), truePos: te.re.tp, falsePos: te.re.fp, falseNeg: te.re.fn },
  maeByEpisodeKind: byKind, trainMae: +tr.mae.toFixed(2),
};
console.log("held-out:", JSON.stringify(holdout, null, 2));

model.meta = {
  trainedOn: "SIMULATED constant-product pool episodes (calm, noisy, V-crash, crash without recovery, single dump, pump), not market data",
  label: "4 x worst further fall in the next 120 s + 3 x fall in the last 30 s, clamped 0..100 (forward-looking)",
  seed: SEED, trainEpisodes: TRAIN_EP, trainSamples: train.length, epochs: EPOCHS, batch: BATCH, lr: LR, sizes: SIZES, holdout,
};
model.sha256 = modelHash(model);
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(model));
console.log(`wrote ${OUT} (${model.sha256.slice(0, 12)}...)`);
