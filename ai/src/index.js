import fs from "node:fs";
import path from "node:path";
import {
  createPublicClient, createWalletClient, http, parseAbi, keccak256, toHex,
  parseEventLogs, defineChain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { AI_DIR, loadEnvFile, getConfig } from "./config.js";
import { computeFeatures, baselineScore, applyGuard } from "./features.js";
import { shouldPublish } from "./policy.js";
import { askLLM } from "./llm.js";

loadEnvFile(path.join(AI_DIR, ".env"));
loadEnvFile(path.join(AI_DIR, "..", ".env")); // reuse POOL/ORACLE/VAULT addresses from the main project .env
const cfg = getConfig();

const poolAbi = parseAbi([
  "event Swap(address indexed sender, address indexed to, bool volToStable, uint256 amountIn, uint256 amountOut, uint256 priceE18)",
  "function priceE18() view returns (uint256)",
]);
const oracleAbi = parseAbi([
  "function publishRisk(uint8 score, bytes32 reasonHash) returns (uint256)",
  "function signer() view returns (address)",
  "event RiskUpdated(uint256 indexed epoch, uint8 score, uint256 timestamp, bytes32 reasonHash)",
]);
const vaultAbi = parseAbi(["function riskOff() view returns (bool)"]);

const chain = defineChain({
  id: cfg.chainId,
  name: "target",
  nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [cfg.rpcUrl] } },
});
const pub = createPublicClient({ chain, transport: http(cfg.rpcUrl) });
const account = cfg.dryRun ? null : privateKeyToAccount(cfg.aiPrivateKey);
const wallet = account ? createWalletClient({ account, chain, transport: http(cfg.rpcUrl) }) : null;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowSec = () => Math.floor(Date.now() / 1000);
const stamp = () => new Date().toISOString().slice(11, 19);
const log = (...a) => console.log(`[${stamp()}]`, ...a);

let stopping = false;
process.on("SIGINT", () => { stopping = true; });
process.on("SIGTERM", () => { stopping = true; });

const samples = [];
const blockTs = new Map();
let lastBlock = 0n;
let lastPublished = null; // { ts, score }
let lastEvalAt = 0;
let newSwaps = 0;

async function blockTimestamp(n) {
  if (blockTs.has(n)) return blockTs.get(n);
  const b = await pub.getBlock({ blockNumber: n });
  const t = Number(b.timestamp);
  blockTs.set(n, t);
  if (blockTs.size > 500) blockTs.delete(blockTs.keys().next().value);
  return t;
}

async function pullSwaps() {
  const head = await pub.getBlockNumber();
  if (head <= lastBlock) return;
  const from = head - lastBlock > 150n ? head - 150n : lastBlock + 1n; // public RPCs cap getLogs ranges
  const logs = await pub.getLogs({ address: cfg.pool, event: poolAbi[0], fromBlock: from, toBlock: head });
  for (const l of logs) {
    const a = l.args;
    samples.push({
      ts: await blockTimestamp(l.blockNumber),
      price: Number(a.priceE18) / 1e18,
      kind: "swap",
      sellVol: a.volToStable,
      amountIn: Number(a.amountIn) / 1e18,
      block: Number(l.blockNumber),
    });
    newSwaps++;
  }
  lastBlock = head;
  const cutoff = nowSec() - cfg.windowSec * 3;
  while (samples.length > 1 && samples[0].ts < cutoff && samples[1].ts < cutoff) samples.shift();
}

async function readRiskOff() {
  if (!cfg.vault) return false;
  return pub.readContract({ address: cfg.vault, abi: vaultAbi, functionName: "riskOff" });
}

async function evaluate() {
  const now = nowSec();
  const f = computeFeatures(samples, now, cfg.windowSec);
  const base = baselineScore(f);

  let llm = null;
  let final = base;
  let reason = "calm: no swaps in window";
  let fallback = false;

  if (f.swapCount > 0 || base >= 20) {
    try {
      llm = await askLLM(f, base, cfg);
      final = applyGuard(llm.score, base, cfg.guardBand);
      reason = llm.reason;
    } catch (e) {
      fallback = true;
      final = base;
      reason = `fallback to rule score (LLM unavailable: ${String(e.message).slice(0, 80)})`;
      log("LLM error:", e.message);
    }
  }

  const riskOff = await readRiskOff();
  const decision = shouldPublish({
    score: final, last: lastPublished, vaultRiskOff: riskOff, now,
    high: cfg.high, low: cfg.low, minIntervalSec: cfg.minPublishIntervalSec,
    delta: cfg.deltaToPublish, heartbeatSec: cfg.heartbeatSec,
  });

  log(
    `price=${f.currentPrice} dd=${f.currentDrawdownPct}% swaps=${f.swapCount} ` +
      `rule=${base} llm=${llm ? llm.score : "-"} final=${final} vaultRiskOff=${riskOff} ` +
      `-> ${decision.publish ? "PUBLISH" : "hold"} (${decision.why})`,
  );
  if (!decision.publish) return;

  const reasonText = `${reason} | rule=${base} llm=${llm ? llm.score : "n/a"} final=${final}`;
  const reasonHash = keccak256(toHex(reasonText));
  const entry = {
    time: new Date().toISOString(), features: f, ruleScore: base,
    llm: llm ? { score: llm.score, model: llm.model, reason: llm.reason } : null,
    fallback, finalScore: final, reasonText, reasonHash, why: decision.why, vaultRiskOff: riskOff,
  };

  if (cfg.dryRun) {
    log("DRY_RUN: would publish", final, "|", reasonText);
    lastPublished = { ts: now, score: final };
    return;
  }

  const hash = await wallet.writeContract({
    address: cfg.oracle, abi: oracleAbi, functionName: "publishRisk", args: [final, reasonHash],
  });
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  const ev = parseEventLogs({ abi: oracleAbi, logs: rcpt.logs, eventName: "RiskUpdated" })[0];
  entry.txHash = hash;
  entry.block = Number(rcpt.blockNumber);
  entry.epoch = ev ? Number(ev.args.epoch) : null;
  lastPublished = { ts: nowSec(), score: final };
  fs.appendFileSync(cfg.logPath, JSON.stringify(entry) + "\n");
  log(`PUBLISHED epoch=${entry.epoch} score=${final} tx=${hash}`);
  log(`  reason: ${reasonText}`);
}

async function main() {
  log(`Guardian AI service. chain=${cfg.chainId} pool=${cfg.pool} oracle=${cfg.oracle}`);
  log(`LLM: ${cfg.provider === "openai" ? cfg.openaiModel : "MOCK (offline test)"}  dryRun=${cfg.dryRun}`);

  if (!cfg.dryRun) {
    const s = await pub.readContract({ address: cfg.oracle, abi: oracleAbi, functionName: "signer" });
    if (s.toLowerCase() !== account.address.toLowerCase()) {
      console.error(
        `\nThis wallet (${account.address}) is NOT the oracle's signer (${s}).\n` +
          `Run setSigner from the owner first (see README, Week 3).`,
      );
      process.exit(1);
    }
    const bal = await pub.getBalance({ address: account.address });
    log(`AI wallet ${account.address} balance=${Number(bal) / 1e18} ETH`);
    if (bal === 0n) {
      console.error("AI wallet has no ETH for gas. Send it ~0.005 Base Sepolia ETH.");
      process.exit(1);
    }
  }

  // seed sample so the first swap has a "before" price
  const p0 = await pub.readContract({ address: cfg.pool, abi: poolAbi, functionName: "priceE18" });
  samples.push({ ts: nowSec(), price: Number(p0) / 1e18, kind: "seed" });
  lastBlock = await pub.getBlockNumber();
  log(`watching swaps from block ${lastBlock}, start price ${Number(p0) / 1e18}`);

  while (!stopping) {
    try {
      await pullSwaps();
      const due = nowSec() - lastEvalAt >= cfg.evalIntervalSec;
      if (newSwaps > 0 || due) {
        newSwaps = 0;
        lastEvalAt = nowSec();
        await evaluate();
      }
    } catch (e) {
      log("tick error:", e.shortMessage || e.message);
    }
    await sleep(cfg.pollMs);
  }
  log("stopped");
}

main().catch((e) => { console.error(e); process.exit(1); });
