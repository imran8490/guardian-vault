/// One verdict = LLM call + deterministic guard band, with a rule-score fallback if the API fails.
/// Kept separate from index.js so every failure path can be unit-tested without a chain or a key.
import { askLLM } from "./llm.js";
import { applyGuard, applyGuardCalmCap, mixModelScore } from "./features.js";
import { predict } from "./nn.js";

export async function scoreVerdict(features, base, cfg, ask = askLLM) {
  const quiet = features.swapCount === 0 && base < 20;
  if (quiet) {
    return { llm: null, nn: null, final: base, reason: "calm: no swaps in window", fallback: false, trace: null, guarded: false };
  }
  // Optional neural network (cfg.nnModel is only set when NN_ENABLED=1): deterministic, same features as the LLM.
  const nn = cfg.nnModel ? predict(cfg.nnModel, features).score : null;
  const w = cfg.nnWeight ?? 0.5;
  const mode = cfg.nnMode ?? "blend";
  const calmMax = cfg.calmRule ?? cfg.nnCalmRule ?? 5;
  const asym = nn !== null && mode === "asym";
  const capped = cfg.calmCap === true || asym;   // the calm cap is its own switch; asym NN mode always uses it
  const guard = (s) => (capped ? applyGuardCalmCap(s, base, cfg.guardBand, cfg.low ?? 30, calmMax) : applyGuard(s, base, cfg.guardBand));
  try {
    const llm = await ask(features, base, cfg);
    const modelScore = mixModelScore(llm.score, nn, { w, mode, base, calmMax });
    const final = guard(modelScore);
    return {
      llm, nn, modelScore, final, reason: llm.reason, fallback: false, trace: llm.trace ?? null, calmCap: capped ? { low: cfg.low ?? 30, calmMax } : null,
      guarded: final !== modelScore, // true when the guard band overrode the model score
    };
  } catch (e) {
    const msg = String(e.message).slice(0, 80);
    return {
      llm: null, nn, final: nn === null ? base : guard(nn), fallback: true, trace: null, guarded: false, calmCap: capped && nn !== null ? { low: cfg.low ?? 30, calmMax } : null,
      reason: nn === null
        ? `fallback to rule score (LLM unavailable: ${msg})`
        : `fallback to neural network score inside the rule band (LLM unavailable: ${msg})`,
      error: String(e.message),
    };
  }
}

/// Pretty console view of the OpenAI exchange for demos (never contains the API key).
export function formatTrace(trace) {
  if (!trace) return "";
  const b = trace.request.body;
  const user = b.messages.find((m) => m.role === "user")?.content ?? "";
  const u = trace.response.usage;
  return [
    `  OpenAI REQUEST  POST ${trace.request.url}`,
    `    model=${b.model} temperature=${b.temperature} response_format=${b.response_format?.type}`,
    `    system: ${b.messages[0].content.split("\n")[0]} ... (${b.messages[0].content.length} chars)`,
    `    user:   ${user}`,
    `  OpenAI RESPONSE (${trace.latencyMs} ms, attempt ${trace.attempt}, model ${trace.response.model}` +
      (u ? `, tokens ${u.prompt_tokens}+${u.completion_tokens}` : "") + `)`,
    `    ${trace.response.content.replace(/\s+/g, " ")}`,
  ].join("\n");
}
