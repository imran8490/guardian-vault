import { test } from "node:test";
import assert from "node:assert/strict";
import { keccak256, toHex } from "viem";
import { verifyEntry } from "../src/replay.js";

const features = {
  windowSec: 300, currentPrice: 0.83, windowStartPrice: 1, changePct: -17, currentDrawdownPct: 17.18,
  maxDrawdownPct: 17.18, swapCount: 1, sellCount: 1, buyCount: 0, sellVolumeVol: 1000, buyVolumeStable: 0,
  maxSwapImpactPct: 17.18, maxDropImpactPct: 17.18, lastSwapImpactPct: -17.18, secondsSinceLastSwap: 8,
};

function entry(over = {}) {
  const rule = 60; // round(3.5 * 17.18)
  const reasonText = `drop | rule=${rule} llm=70 final=70`;
  return {
    time: "2026-11-18T00:00:00Z", features, ruleScore: rule,
    llm: { score: 70, model: "gpt-4o-mini", reason: "drop" },
    openai: {
      request: { body: { messages: [{ role: "system", content: "s" }, { role: "user", content: JSON.stringify({ features, ruleBasedScore: rule }) }] } },
      response: { content: JSON.stringify({ score: 70, reason: "drop" }) },
    },
    guarded: false, fallback: false, finalScore: 70, reasonText, reasonHash: keccak256(toHex(reasonText)), epoch: 1,
    ...over,
  };
}

test("a genuine entry verifies", () => {
  assert.deepEqual(verifyEntry(entry()).problems, []);
});
test("a tampered final score is caught", () => {
  assert.ok(verifyEntry(entry({ finalScore: 100 })).problems.length > 0);
});
test("a tampered reason hash is caught", () => {
  assert.ok(verifyEntry(entry({ reasonHash: "0x" + "00".repeat(32) })).problems.some((p) => p.includes("reasonHash")));
});
test("edited features no longer match the rule score or the OpenAI request", () => {
  const e = entry();
  e.features = { ...features, currentDrawdownPct: 1 };
  assert.ok(verifyEntry(e).problems.length >= 2);
});
test("guard band: model 70 on a calm market is clamped to rule+30", () => {
  const rule = 0;
  const reasonText = `calm | rule=${rule} llm=70 final=30`;
  const e = entry({
    ruleScore: rule, finalScore: 30, guarded: true, reasonText, reasonHash: keccak256(toHex(reasonText)),
    features: { ...features, currentDrawdownPct: 0 },
  });
  e.openai.request.body.messages[1].content = JSON.stringify({ features: e.features, ruleBasedScore: rule });
  assert.deepEqual(verifyEntry(e).problems, []);
});
test("older entry without an OpenAI exchange is a note, not a failure", () => {
  const e = entry();
  delete e.openai;
  const r = verifyEntry(e);
  assert.deepEqual(r.problems, []);
  assert.equal(r.notes.length, 1);
});
