import test from "node:test";
import assert from "node:assert/strict";
import { computeFeatures, baselineScore, applyGuard } from "../src/features.js";
import { shouldPublish } from "../src/policy.js";

const W = 300;
const seed = (ts, price = 1) => ({ ts, price, kind: "seed" });
const sell = (ts, price, amt = 1000) => ({ ts, price, kind: "swap", sellVol: true, amountIn: amt });
const buy = (ts, price, amt = 1000) => ({ ts, price, kind: "swap", sellVol: false, amountIn: amt });

test("calm market scores 0", () => {
  const f = computeFeatures([seed(0)], 100, W);
  assert.equal(f.swapCount, 0);
  assert.equal(baselineScore(f), 0);
});

test("single huge dump (-55%) hits the cap", () => {
  const f = computeFeatures([seed(0), sell(10, 0.445, 5000)], 20, W);
  assert.equal(f.currentDrawdownPct, 55.5);
  assert.equal(f.sellCount, 1);
  assert.equal(baselineScore(f), 100);
});

test("staged crash: score climbs with each sell", () => {
  const s = [seed(0)];
  const scores = [];
  [[10, 0.81], [30, 0.66], [50, 0.52]].forEach(([ts, p]) => {
    s.push(sell(ts, p, 1000));
    scores.push(baselineScore(computeFeatures(s, ts + 1, W)));
  });
  assert.ok(scores[0] >= 60 && scores[0] < 80, `first dump ${scores[0]}`);
  assert.ok(scores[1] > scores[0]);
  assert.equal(scores[2], 100);
});

test("recovery lowers the score (current drawdown, not max)", () => {
  const s = [seed(0), sell(10, 0.445, 5000), buy(40, 0.98, 3300)];
  const f = computeFeatures(s, 50, W);
  assert.ok(f.maxDrawdownPct > 50);
  assert.ok(f.currentDrawdownPct < 5);
  assert.ok(baselineScore(f) <= 30, `score ${baselineScore(f)}`);
});

test("old samples fall out of the window; last pre-window sample is the reference", () => {
  const s = [seed(0), sell(10, 0.5)];
  const f = computeFeatures(s, 1000, W); // everything older than window
  assert.equal(f.swapCount, 0);
  assert.equal(f.currentDrawdownPct, 0);
  assert.equal(baselineScore(f), 0);
});

test("guard: LLM cannot invent a crash in calm market or hide an obvious one", () => {
  assert.equal(applyGuard(95, 0, 30), 30);
  assert.equal(applyGuard(5, 100, 30), 70);
  assert.equal(applyGuard(80, 56, 30), 80); // inside the band the LLM decides
  assert.equal(applyGuard(10, 56, 30), 26);
});

const base = { high: 70, low: 30, minIntervalSec: 20, delta: 15, heartbeatSec: 240 };
test("policy: de-risk needed publishes", () => {
  const r = shouldPublish({ ...base, score: 90, last: { ts: 0, score: 5 }, vaultRiskOff: false, now: 100 });
  assert.equal(r.publish, true);
});
test("policy: rate limit wins", () => {
  const r = shouldPublish({ ...base, score: 90, last: { ts: 95, score: 90 }, vaultRiskOff: false, now: 100 });
  assert.equal(r.publish, false);
});
test("policy: still dangerous after skipped verdict => republish (epoch is consumed by reactive)", () => {
  const r = shouldPublish({ ...base, score: 95, last: { ts: 0, score: 92 }, vaultRiskOff: false, now: 30 });
  assert.equal(r.publish, true);
});
test("policy: already risk-off and still dangerous => no spam", () => {
  const r = shouldPublish({ ...base, score: 95, last: { ts: 0, score: 92 }, vaultRiskOff: true, now: 100 });
  assert.equal(r.publish, false);
});
test("policy: risk-off and calm => re-risk publish", () => {
  const r = shouldPublish({ ...base, score: 10, last: { ts: 0, score: 92 }, vaultRiskOff: true, now: 100 });
  assert.equal(r.publish, true);
});
test("policy: first verdict, big move, heartbeat", () => {
  assert.equal(shouldPublish({ ...base, score: 5, last: null, vaultRiskOff: false, now: 1 }).publish, true);
  assert.equal(shouldPublish({ ...base, score: 50, last: { ts: 0, score: 20 }, vaultRiskOff: false, now: 60 }).publish, true);
  assert.equal(shouldPublish({ ...base, score: 22, last: { ts: 0, score: 20 }, vaultRiskOff: false, now: 60 }).publish, false);
  assert.equal(shouldPublish({ ...base, score: 22, last: { ts: 0, score: 20 }, vaultRiskOff: false, now: 300 }).publish, true);
});
