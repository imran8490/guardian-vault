/// One verdict = LLM call + deterministic guard band, with a rule-score fallback if the API fails.
/// Kept separate from index.js so every failure path can be unit-tested without a chain or a key.
import { askLLM } from "./llm.js";
import { applyGuard } from "./features.js";

export async function scoreVerdict(features, base, cfg, ask = askLLM) {
  const quiet = features.swapCount === 0 && base < 20;
  if (quiet) {
    return { llm: null, final: base, reason: "calm: no swaps in window", fallback: false, trace: null, guarded: false };
  }
  try {
    const llm = await ask(features, base, cfg);
    const final = applyGuard(llm.score, base, cfg.guardBand);
    return {
      llm, final, reason: llm.reason, fallback: false, trace: llm.trace ?? null,
      guarded: final !== llm.score, // true when the guard band overrode the model
    };
  } catch (e) {
    return {
      llm: null, final: base, fallback: true, trace: null, guarded: false,
      reason: `fallback to rule score (LLM unavailable: ${String(e.message).slice(0, 80)})`,
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
