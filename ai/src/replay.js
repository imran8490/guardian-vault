/// Replay verifier: re-checks every verdict in ai/verdicts.jsonl without trusting the AI service.
///
///   node src/replay.js                       # offline checks on every entry
///   node src/replay.js --onchain --last 20   # also compare the last 20 verdicts with the RiskUpdated event on Base Sepolia
///   node src/replay.js --since 2026-11-17    # only entries from that day on (older entries predate the current rule score)
///
/// What it proves, entry by entry:
///   1. the rule score is what the deterministic formula gives for the logged features
///   2. the final score is the model's score clamped to rule score +/- guard band (or the rule score when
///      the model was not used: calm window or OpenAI failure)
///   3. the on-chain reason hash is keccak256 of the logged reason text, and that text names the same scores
///   4. the OpenAI request really contained those features and the response really contained that score
///   5. (--onchain) the oracle's RiskUpdated event has the same epoch, score and reason hash
/// It cannot prove the model is "right", only that the published number follows from the logged inputs.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createPublicClient, http, parseAbi, parseEventLogs, keccak256, toHex } from "viem";
import { baselineScore, applyGuard } from "./features.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const oracleAbi = parseAbi([
  "event RiskUpdated(uint256 indexed epoch, uint8 score, uint256 timestamp, bytes32 reasonHash)",
]);

const sameJson = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/// Pure, offline. Returns { problems, notes }: problems make an entry inconsistent, notes are only informational
/// (older entries were logged before the OpenAI request/response trace existed, so check 4 cannot run on them).
export function verifyEntry(e, { guardBand = 30 } = {}) {
  const problems = [];
  const notes = [];
  const f = e.features;

  const rule = baselineScore(f);
  if (rule !== e.ruleScore) problems.push(`rule score ${e.ruleScore} != ${rule} recomputed from the logged features`);

  const modelUsed = e.llm && typeof e.llm.score === "number";
  const expected = modelUsed ? applyGuard(e.llm.score, e.ruleScore, guardBand) : e.ruleScore;
  if (expected !== e.finalScore) {
    problems.push(
      modelUsed
        ? `final ${e.finalScore} != model ${e.llm.score} clamped to rule ${e.ruleScore} +/- ${guardBand} (= ${expected})`
        : `final ${e.finalScore} != rule score ${e.ruleScore} (no model verdict used)`,
    );
  }
  if (modelUsed && typeof e.guarded === "boolean" && e.guarded !== (e.finalScore !== e.llm.score)) {
    problems.push(`guarded flag is ${e.guarded} but model ${e.llm.score} vs final ${e.finalScore}`);
  }

  if (keccak256(toHex(e.reasonText)) !== e.reasonHash) problems.push("reasonHash is not keccak256(reasonText)");
  const tail = ` | rule=${e.ruleScore} llm=${modelUsed ? e.llm.score : "n/a"} final=${e.finalScore}`;
  if (!e.reasonText.endsWith(tail)) problems.push(`reason text does not end with "${tail.trim()}"`);

  if (e.openai) {
    try {
      const body = e.openai.request?.body;
      const user = JSON.parse(body.messages.find((m) => m.role === "user").content);
      if (!sameJson(user.features, f)) problems.push("OpenAI request features differ from the logged features");
      if (user.ruleBasedScore !== e.ruleScore) problems.push("OpenAI request ruleBasedScore differs from the logged rule score");
      const answer = JSON.parse(e.openai.response.content);
      if (modelUsed && answer.score !== e.llm.score) problems.push(`OpenAI response score ${answer.score} != logged model score ${e.llm.score}`);
    } catch (err) {
      problems.push(`could not parse the OpenAI exchange: ${err.message}`);
    }
  } else if (modelUsed) {
    notes.push("legacy entry: model score logged without the OpenAI request/response, so check 4 was skipped");
  }
  return { problems, notes };
}

async function checkOnchain(entries, rpc) {
  const client = createPublicClient({ transport: http(rpc) });
  const out = new Map();
  for (const e of entries) {
    const problems = [];
    try {
      const rcpt = await client.getTransactionReceipt({ hash: e.txHash });
      const ev = parseEventLogs({ abi: oracleAbi, logs: rcpt.logs, eventName: "RiskUpdated" })[0];
      if (!ev) problems.push("no RiskUpdated event in the transaction");
      else {
        if (Number(ev.args.epoch) !== e.epoch) problems.push(`on-chain epoch ${ev.args.epoch} != logged ${e.epoch}`);
        if (Number(ev.args.score) !== e.finalScore) problems.push(`on-chain score ${ev.args.score} != logged ${e.finalScore}`);
        if (ev.args.reasonHash !== e.reasonHash) problems.push("on-chain reasonHash differs from the logged one");
      }
    } catch (err) {
      problems.push(`on-chain lookup failed: ${String(err.shortMessage || err.message).slice(0, 100)}`);
    }
    out.set(e, problems);
  }
  return out;
}

function parseArgs(argv) {
  const a = { file: path.join(here, "..", "verdicts.jsonl"), onchain: false, last: 20, since: null, quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const v = argv[i];
    if (v === "--onchain") a.onchain = true;
    else if (v === "--last") a.last = Number(argv[++i]);
    else if (v === "--since") a.since = argv[++i];
    else if (v === "--quiet") a.quiet = true;
    else if (!v.startsWith("--")) a.file = v;
  }
  return a;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const guardBand = process.env.GUARD_BAND ? Number(process.env.GUARD_BAND) : 30;
  const rpc = process.env.RPC_URL || process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org";

  let entries = fs.readFileSync(args.file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  if (args.since) entries = entries.filter((e) => e.time >= args.since);
  if (entries.length === 0) { console.log("no entries to check"); return; }

  let bad = 0, withModel = 0, fallback = 0, guarded = 0, legacy = 0, traced = 0;
  const failures = [];
  for (const e of entries) {
    const { problems: p, notes } = verifyEntry(e, { guardBand });
    if (notes.length) legacy++;
    if (e.openai) traced++;
    if (e.llm) withModel++;
    if (e.fallback) fallback++;
    if (e.guarded) guarded++;
    if (p.length) { bad++; failures.push({ e, p }); }
  }

  let onchain = null;
  if (args.onchain) {
    const sample = entries.filter((e) => e.txHash && e.epoch != null).slice(-args.last);
    onchain = await checkOnchain(sample, rpc);
  }

  console.log(`Replay of ${entries.length} verdicts from ${args.file}`);
  console.log(`  ${entries.length - bad} consistent, ${bad} inconsistent  |  with a model score: ${withModel}, rule-score fallback: ${fallback}, guard band overrode the model: ${guarded}`);
  console.log(`  OpenAI request/response re-checked on ${traced} entries; ${legacy} older entries have no logged exchange (checks 1-3 still ran)`);
  if (!args.quiet) {
    for (const { e, p } of failures.slice(0, 20)) console.log(`  X epoch ${e.epoch ?? "?"} (${e.time}): ${p.join("; ")}`);
    if (failures.length > 20) console.log(`  ... and ${failures.length - 20} more`);
  }
  let chainBad = 0;
  if (onchain) {
    for (const [e, p] of onchain) {
      if (p.length) { chainBad++; if (!args.quiet) console.log(`  X on-chain epoch ${e.epoch}: ${p.join("; ")}`); }
    }
    console.log(`  on-chain: ${onchain.size - chainBad} of ${onchain.size} verdicts match their RiskUpdated event (rpc ${rpc})`);
  }
  process.exitCode = bad || chainBad ? 1 : 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e); process.exit(2); });
}
