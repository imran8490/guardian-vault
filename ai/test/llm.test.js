import test from "node:test";
import assert from "node:assert/strict";
import { askLLM, parseVerdict } from "../src/llm.js";

const cfg = { provider: "openai", openaiKey: "sk-test", openaiModel: "m", openaiBase: "http://x", llmTimeoutMs: 1000 };
const feats = { currentPrice: 0.5 };
const ok = (content) => async () => ({
  ok: true, json: async () => ({ model: "m-1", choices: [{ message: { content } }] }),
});

test("parses a clean JSON verdict", async () => {
  const r = await askLLM(feats, 50, cfg, ok('{"score": 88, "reason": "sell streak"}'));
  assert.deepEqual([r.score, r.reason, r.model], [88, "sell streak", "m-1"]);
});

test("clamps out-of-range score and trims reason", async () => {
  const r = parseVerdict(JSON.stringify({ score: 250.4, reason: "x".repeat(500) }));
  assert.equal(r.score, 100);
  assert.equal(r.reason.length, 200);
});

test("extracts JSON wrapped in prose", () => {
  assert.equal(parseVerdict('Sure! {"score": 12, "reason": "calm"} thanks').score, 12);
});

test("rejects non-numeric / non-JSON output", async () => {
  assert.throws(() => parseVerdict('{"score":"high"}'));
  await assert.rejects(askLLM(feats, 50, cfg, ok("no json here")));
});

test("retries once then succeeds", async () => {
  let n = 0;
  const f = async () => {
    n++;
    if (n === 1) return { ok: false, status: 500, text: async () => "boom" };
    return ok('{"score": 40, "reason": "ok"}')();
  };
  assert.equal((await askLLM(feats, 50, cfg, f)).score, 40);
  assert.equal(n, 2);
});

test("HTTP failure twice => throws (caller falls back to rule score)", async () => {
  const f = async () => ({ ok: false, status: 401, text: async () => "bad key" });
  await assert.rejects(askLLM(feats, 50, cfg, f), /401/);
});

test("sends key and strict-JSON request, never leaks key in body", async () => {
  let seen;
  const f = async (url, init) => { seen = { url, init }; return ok('{"score":1,"reason":"r"}')(); };
  await askLLM(feats, 50, cfg, f);
  assert.equal(seen.url, "http://x/chat/completions");
  assert.equal(seen.init.headers.authorization, "Bearer sk-test");
  assert.ok(!seen.init.body.includes("sk-test"));
  assert.equal(JSON.parse(seen.init.body).response_format.type, "json_object");
});

test("mock provider is explicit and offline", async () => {
  const r = await askLLM(feats, 33, { provider: "mock" });
  assert.equal(r.score, 33);
});
