// Off-chain safeguards: what happens when OpenAI fails or the model is simply wrong.
// (The on-chain half of the same threat table is in test/Guardian.t.sol; see docs/SAFETY.md.)
import test from "node:test";
import assert from "node:assert/strict";
import { scoreVerdict, formatTrace } from "../src/scoring.js";

const cfg = {
  provider: "openai", openaiKey: "sk-secret-key", openaiModel: "gpt-4o-mini",
  openaiBase: "http://x", llmTimeoutMs: 50, guardBand: 30,
};
const crash = { swapCount: 4, currentDrawdownPct: 28 };   // rule score 98
const calm = { swapCount: 2, currentDrawdownPct: 0.4 };   // rule score 1
const reply = (content) => async () => ({
  ok: true, json: async () => ({ id: "c1", model: "gpt-4o-mini-x", usage: { prompt_tokens: 10, completion_tokens: 5 }, choices: [{ message: { content } }] }),
});

// ---- API failure: the service must degrade to the deterministic rule score, never crash or stall

test("API down (HTTP 500 twice) => falls back to rule score and says so", async () => {
  const fetch500 = async () => ({ ok: false, status: 500, text: async () => "upstream down" });
  const r = await scoreVerdict(crash, 98, cfg, (f, b, c) => import("../src/llm.js").then((m) => m.askLLM(f, b, c, fetch500)));
  assert.equal(r.fallback, true);
  assert.equal(r.final, 98);
  assert.match(r.reason, /fallback to rule score/);
  assert.match(r.error, /500/);
});

test("bad API key (401) => fallback, no throw", async () => {
  const f401 = async () => ({ ok: false, status: 401, text: async () => "invalid key" });
  const r = await scoreVerdict(crash, 98, cfg, (f, b, c) => import("../src/llm.js").then((m) => m.askLLM(f, b, c, f401)));
  assert.equal(r.fallback, true);
  assert.equal(r.final, 98);
});

test("network timeout (request never answers) => fallback within the timeout", async () => {
  const hang = (url, init) => new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(new Error("aborted"))));
  const t0 = Date.now();
  const r = await scoreVerdict(crash, 98, cfg, (f, b, c) => import("../src/llm.js").then((m) => m.askLLM(f, b, c, hang)));
  assert.equal(r.fallback, true);
  assert.ok(Date.now() - t0 < 1000, "must not hang");
});

test("model returns garbage / empty content => fallback", async () => {
  for (const bad of ["I think it is risky", "", '{"score":"very high"}']) {
    const r = await scoreVerdict(crash, 98, cfg, (f, b, c) => import("../src/llm.js").then((m) => m.askLLM(f, b, c, reply(bad))));
    assert.equal(r.fallback, true, `content=${JSON.stringify(bad)}`);
  }
});

test("fallback in a calm market stays calm (no false alarm when the API is down)", async () => {
  const boom = async () => { throw new Error("ECONNRESET"); };
  const r = await scoreVerdict(calm, 1, cfg, boom);
  assert.equal(r.final, 1);
  assert.equal(r.fallback, true);
});

// ---- wrong AI verdict: the guard band (rule score +/- 30) bounds what the model can do

test("model hallucinates a crash in a calm market => clamped below the de-risk threshold", async () => {
  const r = await scoreVerdict(calm, 1, cfg, async () => ({ score: 99, reason: "panic!", model: "m" }));
  assert.equal(r.final, 31);
  assert.ok(r.final < 70, "cannot reach HIGH (70) when the rule score is ~0");
  assert.equal(r.guarded, true);
});

test("model ignores an obvious crash => clamped above the de-risk threshold", async () => {
  const r = await scoreVerdict(crash, 98, cfg, async () => ({ score: 2, reason: "all fine", model: "m" }));
  assert.equal(r.final, 68 /* 98 - 30 */);
  const r2 = await scoreVerdict(crash, 100, cfg, async () => ({ score: 0, reason: "all fine", model: "m" }));
  assert.equal(r2.final, 70);
  assert.ok(r2.final >= 70, "a rule score of 100 always de-risks, whatever the model says");
});

test("model inside the band is respected (guard only fires when needed)", async () => {
  const r = await scoreVerdict(crash, 98, cfg, async () => ({ score: 85, reason: "sell streak", model: "m" }));
  assert.equal(r.final, 85);
  assert.equal(r.guarded, false);
});

// ---- the demo view of the OpenAI exchange

test("trace shows request + response and never contains the API key", async () => {
  const { askLLM } = await import("../src/llm.js");
  const r = await scoreVerdict(crash, 98, cfg, (f, b, c) => askLLM(f, b, c, reply('{"score": 90, "reason": "sell streak, -28%"}')));
  assert.equal(r.fallback, false);
  assert.equal(r.trace.request.body.model, "gpt-4o-mini");
  assert.equal(r.trace.response.content, '{"score": 90, "reason": "sell streak, -28%"}');
  const printed = formatTrace(r.trace);
  assert.match(printed, /OpenAI REQUEST/);
  assert.match(printed, /OpenAI RESPONSE/);
  assert.ok(!printed.includes("sk-secret-key"));
  assert.ok(!JSON.stringify(r.trace).includes("sk-secret-key"));
});

test("quiet window with no swaps never calls the model", async () => {
  let called = false;
  const r = await scoreVerdict({ swapCount: 0, currentDrawdownPct: 0 }, 0, cfg, async () => { called = true; });
  assert.equal(called, false);
  assert.equal(r.final, 0);
});
