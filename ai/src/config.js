import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const AI_DIR = path.resolve(here, "..");

/// Tiny .env loader (no dependency, works on any Node >= 18).
/// Same rules as bash `source`: later lines in a file win over earlier ones, empty values are
/// ignored (templates are full of `KEY=`), and anything already set in the real environment
/// (or by a file loaded earlier) wins, so ai/.env beats the project-root .env.
export function loadEnvFile(file) {
  if (!fs.existsSync(file)) return;
  const parsed = {};
  for (const raw of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const line = raw.trim().replace(/^export\s+/, "");
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 1) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (val !== "") parsed[key] = val; // later line wins
  }
  for (const [k, v] of Object.entries(parsed)) {
    if (process.env[k] === undefined || process.env[k] === "") process.env[k] = v;
  }
}

const num = (v, d) => (v === undefined || v === "" ? d : Number(v));

export function getConfig(env = process.env) {
  const need = (k) => {
    const v = env[k];
    if (!v) throw new Error(`Missing ${k} in ai/.env`);
    return v;
  };
  const dryRun = env.DRY_RUN === "1";
  const provider = env.LLM_PROVIDER || "openai";
  return {
    rpcUrl: env.RPC_URL || env.BASE_SEPOLIA_RPC || "https://sepolia.base.org",
    chainId: num(env.CHAIN_ID, 84532),
    pool: need("POOL_ADDRESS"),
    oracle: need("ORACLE_ADDRESS"),
    vault: env.VAULT_ADDRESS || null,
    aiPrivateKey: dryRun ? null : need("AI_PRIVATE_KEY"),
    dryRun,

    provider, // "openai" (real) | "mock" (offline tests only)
    openaiKey: provider === "openai" ? need("OPENAI_API_KEY") : null,
    openaiModel: env.OPENAI_MODEL || "gpt-4o-mini",
    openaiBase: env.OPENAI_BASE_URL || "https://api.openai.com/v1",
    llmTimeoutMs: num(env.LLM_TIMEOUT_MS, 15000),
    showLlm: env.SHOW_LLM !== "0", // print each OpenAI request/response (demo); SHOW_LLM=0 to silence

    windowSec: num(env.WINDOW_SEC, 300),
    pollMs: num(env.POLL_MS, 3000),
    evalIntervalSec: num(env.EVAL_INTERVAL_SEC, 15),
    minPublishIntervalSec: num(env.MIN_PUBLISH_INTERVAL_SEC, 20),
    deltaToPublish: num(env.DELTA_TO_PUBLISH, 15),
    heartbeatSec: num(env.HEARTBEAT_SEC, 240),
    high: num(env.HIGH_THRESHOLD, 70),
    low: num(env.LOW_THRESHOLD, 30),
    guardBand: num(env.GUARD_BAND, 30),
    logPath: env.VERDICT_LOG || path.join(AI_DIR, "verdicts.jsonl"),
  };
}
