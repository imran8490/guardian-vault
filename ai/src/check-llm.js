/// One cheap call to verify the OpenAI key and model BEFORE the live run.
/// Sends a fake staged-crash feature set and a fake calm one; prints what the model answers.
import path from "node:path";
import { AI_DIR, loadEnvFile, getConfig } from "./config.js";
import { askLLM } from "./llm.js";
import { baselineScore, applyGuard } from "./features.js";

loadEnvFile(path.join(AI_DIR, ".env"));
loadEnvFile(path.join(AI_DIR, "..", ".env"));
process.env.POOL_ADDRESS ||= "0x0000000000000000000000000000000000000000";
process.env.ORACLE_ADDRESS ||= "0x0000000000000000000000000000000000000000";
process.env.DRY_RUN = "1";
const cfg = getConfig();

const cases = {
  "staged crash (2 sells, -30%)": {
    windowSec: 300, currentPrice: 0.69, windowStartPrice: 1, changePct: -30.5,
    currentDrawdownPct: 30.5, maxDrawdownPct: 30.5, swapCount: 2, sellCount: 2, buyCount: 0,
    sellVolumeVol: 2000, buyVolumeStable: 0, maxSwapImpactPct: 17.3, maxDropImpactPct: 17.3,
    lastSwapImpactPct: -16.2, secondsSinceLastSwap: 3,
  },
  "calm (one tiny swap)": {
    windowSec: 300, currentPrice: 0.999, windowStartPrice: 1, changePct: -0.1,
    currentDrawdownPct: 0.1, maxDrawdownPct: 0.1, swapCount: 1, sellCount: 1, buyCount: 0,
    sellVolumeVol: 5, buyVolumeStable: 0, maxSwapImpactPct: 0.1, maxDropImpactPct: 0.1,
    lastSwapImpactPct: -0.1, secondsSinceLastSwap: 40,
  },
};

console.log(`model: ${cfg.openaiModel}`);
for (const [name, f] of Object.entries(cases)) {
  const base = baselineScore(f);
  const r = await askLLM(f, base, cfg);
  console.log(`\n${name}\n  rule score : ${base}\n  LLM score  : ${r.score}\n  after guard: ${applyGuard(r.score, base, cfg.guardBand)}\n  reason     : ${r.reason}`);
}
console.log("\nLLM check OK.");
