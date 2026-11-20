import test from "node:test";
import assert from "node:assert/strict";
import { keccak256, toHex } from "viem";
import { computeFeatures, baselineScore, applyGuard, applyGuardCalmCap, mixModelScore } from "../src/features.js";
import { loadModel, predict, featureVector, modelHash, INPUT_NAMES } from "../src/nn.js";
import { scoreVerdict } from "../src/scoring.js";
import { verifyEntry } from "../src/replay.js";

const model = loadModel();
const W = 300;
const seed = (ts, price = 1) => ({ ts, price, kind: "seed" });
const sell = (ts, price, amt = 1000) => ({ ts, price, kind: "swap", sellVol: true, amountIn: amt });
const buy = (ts, price, amt = 2900) => ({ ts, price, kind: "swap", sellVol: false, amountIn: amt });

const crash = [seed(0), sell(10, 0.83), sell(22, 0.69), sell(34, 0.59)];
const mid = computeFeatures(crash, 36, W);                                   // crash still unfolding
const recovered = computeFeatures([...crash, buy(100, 1.0)], 110, W);       // price back at 1.0, crash still in the window
const calmish = computeFeatures([seed(0), sell(10, 0.99, 50), buy(40, 1.0, 50)], 60, W);

test("weights file: inputs match the code and the stored sha256 matches the weights", () => {
  assert.deepEqual(model.inputs, INPUT_NAMES);
  assert.equal(featureVector(mid).length, INPUT_NAMES.length);
  assert.equal(model.sha256, modelHash(model));
  assert.match(model.meta.trainedOn, /SIMULATED/);
});

test("feature vector stays inside [-2, 2] even for absurd inputs", () => {
  const v = featureVector({ ...mid, currentDrawdownPct: 9999, changePct: -9999, maxDropImpactPct: 1e6, lastSwapImpactPct: -1e6, swapCount: 500, sellCount: 500 });
  for (const x of v) assert.ok(x >= -2 && x <= 2);
});

test("deterministic: same features, same score", () => {
  assert.equal(predict(model, mid).score, predict(model, mid).score);
  assert.equal(predict(model, mid).raw, predict(model, mid).raw);
});

test("scores a crash in progress high, a recovered crash low, a calm market low", () => {
  assert.ok(predict(model, mid).score >= 70, `crash in progress: ${predict(model, mid).score}`);
  assert.ok(predict(model, recovered).score <= 30, `recovered: ${predict(model, recovered).score}`);
  assert.ok(predict(model, calmish).score <= 30, `calm: ${predict(model, calmish).score}`);
});

const cfg = { guardBand: 30, nnModel: model, nnWeight: 0.5 };
const llmSays = (score) => async () => ({ score, reason: "stub", model: "stub", trace: null });

test("with the NN on, model score is the weighted mix and the guard band still applies", async () => {
  const base = baselineScore(recovered);
  const nn = predict(model, recovered).score;
  const r = await scoreVerdict(recovered, base, cfg, llmSays(70));
  assert.equal(r.nn, nn);
  assert.equal(r.modelScore, Math.round(0.5 * 70 + 0.5 * nn));
  assert.equal(r.final, applyGuard(r.modelScore, base, 30));
  assert.equal(r.fallback, false);
});

test("NN off (no cfg.nnModel): behaviour is exactly the old LLM + guard band", async () => {
  const base = baselineScore(recovered);
  const r = await scoreVerdict(recovered, base, { guardBand: 30 }, llmSays(70));
  assert.equal(r.nn, null);
  assert.equal(r.final, applyGuard(70, base, 30));
});

test("LLM down with the NN on: falls back to the NN score inside the rule band, and says so", async () => {
  const boom = async () => { throw new Error("fetch failed"); };
  const base = baselineScore(mid);
  const r = await scoreVerdict(mid, base, cfg, boom);
  assert.equal(r.fallback, true);
  assert.equal(r.final, applyGuard(predict(model, mid).score, base, 30));
  assert.match(r.reason, /fallback to neural network score/);
});

test("a quiet window never calls the NN or the model", async () => {
  const quiet = computeFeatures([seed(0)], 100, W);
  const r = await scoreVerdict(quiet, 0, cfg, async () => { throw new Error("must not be called"); });
  assert.equal(r.nn, null);
  assert.equal(r.final, 0);
});

function nnEntry(over = {}) {
  const f = recovered, rule = baselineScore(f), nn = predict(model, f).score, llm = 70;
  const modelScore = Math.round(0.5 * llm + 0.5 * nn);
  const final = applyGuard(modelScore, rule, 30);
  const reasonText = `stub | rule=${rule} llm=${llm} nn=${nn} final=${final}`;
  return {
    features: f, ruleScore: rule, llm: { score: llm, model: "stub", reason: "stub" }, nn: { score: nn, weight: 0.5, model: modelHash(model) },
    guarded: final !== modelScore, fallback: false, finalScore: final, reasonText, reasonHash: keccak256(toHex(reasonText)), epoch: 1,
    ...over,
  };
}

test("replay: an NN verdict is recomputed from the logged features and checks out", () => {
  const r = verifyEntry(nnEntry(), { nnModel: model });
  assert.deepEqual(r.problems.filter((p) => !p.includes("OpenAI")), []);
});

test("replay: a tampered NN score is caught", () => {
  const e = nnEntry();
  e.nn = { ...e.nn, score: e.nn.score + 20 };
  assert.ok(verifyEntry(e, { nnModel: model }).problems.some((p) => p.includes("NN score")));
});

test("replay: a different weights file is a note, not a false alarm", () => {
  const e = nnEntry();
  e.nn = { ...e.nn, model: "00".repeat(32) };
  const r = verifyEntry(e, { nnModel: model });
  assert.ok(r.notes.some((n) => n.includes("weights file differs")));
  assert.ok(!r.problems.some((p) => p.includes("NN score")));
});

// ---- asym mode: the NN can only raise the score unless the rule score says the pool is back at its peak ----
const acfg = { ...cfg, nnMode: "asym", low: 30, nnCalmRule: 5 };
const calmF = { ...recovered, currentDrawdownPct: 0.3 };   // rule 1, crash still in the window

test("asym helpers", () => {
  assert.equal(applyGuardCalmCap(85, 1, 30, 30), 30);    // stale LLM on a recovered pool: no longer stuck at 31
  assert.equal(applyGuardCalmCap(85, 5, 30, 30), 30);
  assert.equal(applyGuardCalmCap(85, 6, 30, 30), 36);    // not calm: the normal band
  assert.equal(applyGuardCalmCap(85, 40, 30, 30), 70);
  assert.equal(applyGuardCalmCap(0, 100, 30, 30), 70);   // lower bound unchanged
  assert.equal(mixModelScore(100, 0, { mode: "asym", base: 88 }), 100);   // not calm: max
  assert.equal(mixModelScore(100, 0, { mode: "asym", base: 1 }), 50);     // calm: blend
  assert.equal(mixModelScore(100, 0, { mode: "blend", base: 88 }), 50);
  assert.equal(mixModelScore(40, null, { mode: "asym", base: 88 }), 40);
});

const finished = computeFeatures(crash, 120, W);               // same crash, 86 s after the last sell: the NN says ~0 (live epochs 195/197)

test("asym: an NN that says 'finished crash' cannot suppress a de-risk (live epochs 195/197)", async () => {
  const f = { ...finished, currentDrawdownPct: 25 };       // rule 88
  const base = baselineScore(f);
  assert.equal(base, 88);
  assert.ok(predict(model, f).score <= 20, "premise: the NN scores a finished crash low");
  const blend = await scoreVerdict(f, base, cfg, llmSays(100));
  const r = await scoreVerdict(f, base, acfg, llmSays(100));
  assert.ok(blend.final < 70, `blend final ${blend.final}: the problem this mode fixes`);
  assert.ok(r.final >= 70, `asym final ${r.final}`);
  assert.equal(r.modelScore, Math.max(100, r.nn));
});

test("asym: a pause in a crash (rule 35) cannot be talked down into an early re-risk by the NN", async () => {
  const f = { ...finished, currentDrawdownPct: 10 };        // rule 35, not calm, NN ~0
  const base = baselineScore(f);
  const r = await scoreVerdict(f, base, acfg, llmSays(40));
  assert.ok(r.final >= 40, `final ${r.final}`);             // max(40, nn), never below the LLM
});

test("asym: stale LLM 85 on a recovered pool (rule 1) can reach the re-risk threshold; blend mode keeps the 31 clamp", async () => {
  const base = baselineScore(calmF);
  assert.equal(base, 1);
  const r = await scoreVerdict(calmF, base, acfg, llmSays(85));
  assert.ok(r.final <= 30, `final ${r.final}`);
  assert.ok((await scoreVerdict(calmF, base, cfg, llmSays(85))).final >= 31);
});

test("asym: a real crash in progress still scores high", async () => {
  const base = baselineScore(mid);
  const r = await scoreVerdict(mid, base, acfg, llmSays(95));
  assert.ok(r.final >= 70);
});

test("asym, LLM down: the NN score goes through the same guard", async () => {
  const boom = async () => { throw new Error("fetch failed"); };
  const r = await scoreVerdict(calmF, 1, acfg, boom);
  assert.equal(r.fallback, true);
  assert.equal(r.final, applyGuardCalmCap(predict(model, calmF).score, 1, 30, 30, 5));
});

test("NN off: nothing changes in any mode", async () => {
  const r = await scoreVerdict(calmF, 1, { guardBand: 30, nnMode: "asym", low: 30 }, llmSays(85));
  assert.equal(r.nn, null);
  assert.equal(r.final, applyGuard(85, 1, 30));
});

function asymEntry(f, llm, over = {}) {
  const rule = baselineScore(f);
  const nn = predict(model, f).score;
  const modelScore = mixModelScore(llm, nn, { w: 0.5, mode: "asym", base: rule, calmMax: 5 });
  const final = applyGuardCalmCap(modelScore, rule, 30, 30, 5);
  const reasonText = `stub | rule=${rule} llm=${llm} nn=${nn} final=${final}`;
  return {
    features: f, ruleScore: rule, llm: { score: llm, model: "stub", reason: "stub" },
    nn: { score: nn, weight: 0.5, model: modelHash(model), mode: "asym", low: 30, calmMax: 5 },
    guarded: final !== modelScore, fallback: false, finalScore: final, reasonText, reasonHash: keccak256(toHex(reasonText)), epoch: 1, ...over,
  };
}

test("replay: asym verdicts (calm and not calm) verify; tampering with the mode, the final score or the NN score is caught", () => {
  for (const [f, llm] of [[calmF, 85], [{ ...mid, currentDrawdownPct: 25 }, 100]]) {
    const e = asymEntry(f, llm);
    assert.deepEqual(verifyEntry(e, { nnModel: model }).problems.filter((p) => !p.includes("OpenAI")), []);
  }
  const g = asymEntry({ ...mid, currentDrawdownPct: 25 }, 100);   // asym keeps 100; the blend rule would give a lower number
  assert.ok(g.finalScore >= 70);
  assert.ok(verifyEntry({ ...g, nn: { ...g.nn, mode: "blend" } }, { nnModel: model }).problems.length > 0, "relabelling asym as blend must not verify");
  assert.ok(verifyEntry({ ...g, finalScore: 60 }, { nnModel: model }).problems.length > 0);
  assert.ok(verifyEntry({ ...g, nn: { ...g.nn, score: g.nn.score + 20 } }, { nnModel: model }).problems.length > 0);
});

// ---- CALM_CAP on its own (no NN) ----
const capCfg = { guardBand: 30, low: 30, calmCap: true, calmRule: 5 };      // no nnModel: plain LLM + guard band + calm cap

test("calm cap without the NN: stale LLM 85 on a recovered pool (rule 1) can re-risk; off by default", async () => {
  const on = await scoreVerdict(calmF, 1, capCfg, llmSays(85));
  const off = await scoreVerdict(calmF, 1, { guardBand: 30, low: 30 }, llmSays(85));
  assert.equal(on.nn, null);
  assert.equal(on.final, 30);
  assert.deepEqual(on.calmCap, { low: 30, calmMax: 5 });
  assert.equal(off.final, 31);            // the old clamp
  assert.equal(off.calmCap, null);
});

test("calm cap never touches a de-risk or a real crash", async () => {
  for (const [f, llm] of [[{ ...finished, currentDrawdownPct: 25 }, 100], [mid, 95], [{ ...finished, currentDrawdownPct: 12 }, 80]]) {
    const base = baselineScore(f);
    const on = await scoreVerdict(f, base, capCfg, llmSays(llm));
    const off = await scoreVerdict(f, base, { guardBand: 30, low: 30 }, llmSays(llm));
    assert.equal(on.final, off.final, `rule ${base}`);
  }
});

test("calm cap only changes scores for rule <= calmRule, and only downwards", async () => {
  for (let base = 0; base <= 100; base++) {
    for (const llm of [0, 10, 30, 50, 70, 85, 100]) {
      const on = applyGuardCalmCap(llm, base, 30, 30, 5);
      const off = applyGuard(llm, base, 30);
      if (base > 5) assert.equal(on, off, `base ${base} llm ${llm}`);
      else assert.ok(on <= off && on <= 30, `base ${base} llm ${llm}: ${on} vs ${off}`);
    }
  }
});

test("replay: a calm-cap verdict without the NN verifies; dropping the calmCap field or changing the score is caught", () => {
  const rule = baselineScore(calmF);
  const final = applyGuardCalmCap(85, rule, 30, 30, 5);
  const reasonText = `stub | rule=${rule} llm=85 final=${final}`;
  const e = {
    features: calmF, ruleScore: rule, llm: { score: 85, model: "stub", reason: "stub" }, nn: null, calmCap: { low: 30, calmMax: 5 },
    guarded: final !== 85, fallback: false, finalScore: final, reasonText, reasonHash: keccak256(toHex(reasonText)), epoch: 1,
  };
  const ok = (x) => verifyEntry(x, { nnModel: model }).problems.filter((p) => !p.includes("OpenAI"));
  assert.deepEqual(ok(e), []);
  assert.equal(final, 30);
  const { calmCap, ...noField } = e;
  assert.ok(ok(noField).length > 0, "pretending no cap was applied must not verify");
  assert.ok(ok({ ...e, finalScore: 31 }).length > 0);
});
