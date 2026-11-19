#!/usr/bin/env python3
"""Aggregate latency benchmark logs written by demo/bench.sh.

Usage: python3 demo/bench_stats.py [bench_dir]      (default: bench)

Reads <bench_dir>/run-*.log (the output of demo/run-demo.sh, which embeds demo/proof.sh output),
writes <bench_dir>/results.json and <bench_dir>/RESULTS.md.

All timings come from on-chain block timestamps (1 s resolution), the same way demo/proof.sh
measures them, so every sample can be re-checked from the tx hashes listed in RESULTS.md.
"""
import glob
import json
import math
import os
import re
import sys

BASE_TX = "https://sepolia.basescan.org/tx/"
LASNA_TX = "https://lasna.reactscan.net/tx/"

BLOCK_RE = re.compile(r"^## Proof for epoch (\d+) \(score (\S+), model ([^)]*)\)", re.M)
SWAP_RE = re.compile(r"^Trigger swap \(Base block (\d+), t=(\d+)\): (0x[0-9a-fA-F]{64})", re.M)
PUB_RE = re.compile(r"^AI publishRisk \(Base block (\d+), t=(\d+)\): (0x[0-9a-fA-F]{64})", re.M)
RX_RE = re.compile(r"^Reactive ActionRequested \(Lasna block (\d+), t=(\d+)\): (0x[0-9a-fA-F]{64})", re.M)
CB_RE = re.compile(r"^Vault (DeRisked|ReRisked) callback \(Base block (\d+), t=(\d+)\): (0x[0-9a-fA-F]{64})", re.M)


def parse_log(path):
    text = open(path, errors="replace").read().replace("\r", "\n")
    parts = BLOCK_RE.split(text)
    # split() with 3 groups -> [pre, epoch, score, model, body, epoch, score, model, body, ...]
    out = []
    for k in range(1, len(parts), 4):
        epoch, score, model, body = int(parts[k]), parts[k + 1], parts[k + 2].strip(), parts[k + 3]
        # a block ends where the run-demo "Done" line starts (it prints after the last proof)
        body = body.split("== Done")[0]
        cb = CB_RE.search(body)
        pub = PUB_RE.search(body)
        if not (cb and pub):
            out.append({"run": os.path.basename(path), "epoch": epoch, "valid": False,
                        "why": "no vault callback or publish line found"})
            continue
        sw = SWAP_RE.search(body)
        rx = RX_RE.search(body)
        s = {
            "run": os.path.basename(path),
            "epoch": epoch,
            "score": score,
            "model": model if model and model not in ("n/a", "None") else "",
            "direction": "de-risk" if cb.group(1) == "DeRisked" else "re-risk",
            "valid": True,
            "pub_t": int(pub.group(2)), "pub_tx": pub.group(3),
            "cb_t": int(cb.group(3)), "cb_tx": cb.group(4),
            "swap_t": int(sw.group(2)) if sw else None, "swap_tx": sw.group(3) if sw else None,
            "rx_t": int(rx.group(2)) if rx else None, "rx_tx": rx.group(3) if rx else None,
        }
        s["pub_to_vault"] = s["cb_t"] - s["pub_t"]
        s["swap_to_pub"] = s["pub_t"] - s["swap_t"] if sw else None
        s["swap_to_vault"] = s["cb_t"] - s["swap_t"] if sw else None
        # Lasna block time vs Base block time: only trust it when it is sensible (sub-minute, non-negative)
        s["pub_to_react"] = s["rx_t"] - s["pub_t"] if rx else None
        s["react_to_vault"] = s["cb_t"] - s["rx_t"] if rx else None
        for key in ("pub_to_react", "react_to_vault"):
            v = s[key]
            if v is not None and not (0 <= v <= 60):
                s[key] = None
        out.append(s)
    return out


def pct(sorted_vals, p):
    """nearest-rank percentile"""
    k = max(1, math.ceil(p / 100 * len(sorted_vals)))
    return sorted_vals[k - 1]


def stats(vals):
    v = sorted(x for x in vals if x is not None)
    if not v:
        return None
    n = len(v)
    med = v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
    return {"n": n, "min": v[0], "median": med, "p95": pct(v, 95), "max": v[-1], "mean": round(sum(v) / n, 1)}


METRICS = [
    ("swap_to_pub", "Trigger swap -> AI verdict on-chain (poll + features + LLM + tx)"),
    ("pub_to_vault", "Verdict on-chain -> vault moved (oracle event -> Lasna -> callback)"),
    ("swap_to_vault", "Trigger swap -> vault moved (end to end)"),
]


def fmt(x):
    if x is None:
        return "n/a"
    return str(int(x)) if float(x).is_integer() else f"{x:.1f}"


def table(samples):
    rows = ["| Step | n | min s | median s | p95 s | max s | mean s |", "|---|---|---|---|---|---|---|"]
    for key, label in METRICS:
        st = stats([s[key] for s in samples])
        if st is None:
            continue
        rows.append(f"| {label} | {st['n']} | {fmt(st['min'])} | {fmt(st['median'])} | {fmt(st['p95'])} | {fmt(st['max'])} | {fmt(st['mean'])} |")
    return "\n".join(rows)


def reserves_cost(bench):
    """REACT reserves are read at the start of every cycle (bench.sh writes reserves.tsv).
    The drop between two consecutive cycles is what the previous cycle cost (a top-up in between shows as an increase and is skipped)."""
    path = os.path.join(bench, "reserves.tsv")
    if not os.path.exists(path):
        return ""
    rows = {}
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 2 and p[0].isdigit() and p[1].isdigit():
            rows[int(p[0])] = int(p[1]) / 1e18
    drops = [rows[n] - rows[n + 1] for n in sorted(rows) if n + 1 in rows and rows[n] - rows[n + 1] >= 0]
    if not drops:
        return ""
    avg = sum(drops) / len(drops)
    return (f"Reserves at the Lasna system contract, read before each cycle: {len(drops)} consecutive pair(s) without a top-up, "
            f"average drop {avg:.4f} REACT per cycle (min {min(drops):.4f}, max {max(drops):.4f}). "
            "One cycle is a de-risk and a re-risk plus the idle verdicts the AI service publishes in between, so this is an upper estimate for one reaction pair.")


def main():
    bench = sys.argv[1] if len(sys.argv) > 1 else "bench"
    logs = sorted(glob.glob(os.path.join(bench, "run-*.log")))
    if not logs:
        sys.exit(f"no run-*.log files in {bench}/ (run demo/bench.sh first)")

    allsamples = []
    for p in logs:
        allsamples += parse_log(p)
    valid = [s for s in allsamples if s["valid"]]
    invalid = [s for s in allsamples if not s["valid"]]
    if not valid:
        sys.exit("no valid samples parsed. Check the logs: each run needs the 'Proof for epoch' blocks.")

    de = [s for s in valid if s["direction"] == "de-risk"]
    re_ = [s for s in valid if s["direction"] == "re-risk"]
    llm = [s for s in valid if s["model"]]
    nollm = [s for s in valid if not s["model"]]

    result = {
        "runs": len(logs), "samples": len(valid), "invalid_samples": len(invalid),
        "overall": {k: stats([s[k] for s in valid]) for k, _ in METRICS},
        "de_risk": {k: stats([s[k] for s in de]) for k, _ in METRICS},
        "re_risk": {k: stats([s[k] for s in re_]) for k, _ in METRICS},
        "with_llm_call": {k: stats([s[k] for s in llm]) for k, _ in METRICS},
        "samples_detail": valid, "invalid": invalid,
    }
    json.dump(result, open(os.path.join(bench, "results.json"), "w"), indent=2)

    md = []
    md.append("# Latency benchmark (Base Sepolia + Reactive Lasna)\n")
    cycles = len({s["run"] for s in valid})
    failed = len(logs) - cycles
    md.append(f"{len(valid)} samples from {cycles} complete demo cycles "
              f"({len(de)} de-risk, {len(re_)} re-risk)"
              + (f"; {failed} further run(s) failed and produced no samples (see the run logs)" if failed else "")
              + ". Each cycle is `demo/run-demo.sh`: a staged crash, the AI verdict, "
              "the Lasna reaction and the vault de-risk, then a recovery swap and the re-risk.\n")
    md.append("## How it is measured\n")
    md.append("- All times are on-chain block timestamps (1 s resolution, so each number is +/-1 s), computed by `demo/proof.sh`. "
              "No wall-clock of the measuring machine is involved, and every sample below links its transactions.\n"
              "- The *trigger swap* is the last pool swap before the AI verdict, as in `demo/proof.sh`. "
              "The swap-to-verdict step includes the AI service's polling cadence (defaults in `ai/src/config.js`: poll 3 s, evaluate at least every 15 s), "
              "feature computation, the OpenAI call and transaction confirmation, so it is dominated by the AI, not by Reactive Network.\n"
              "- *Verdict on-chain -> vault moved* is the part Reactive Network owns: oracle event, Lasna reaction, callback delivery.\n"
              "- The Lasna block timestamps are not used: they have the same 1 s resolution but come from a different chain clock, so splitting the Reactive part further would not be meaningful.\n"
              f"- With n = {len(valid)}, p95 is essentially the maximum. These are testnet numbers on public RPCs, not a performance claim.\n")
    md.append("## All samples\n")
    md.append(table(valid) + "\n")
    if de and re_:
        md.append("## De-risk (crash)\n")
        md.append(table(de) + "\n")
        md.append("## Re-risk (recovery)\n")
        md.append(table(re_) + "\n")
    if llm and nollm:
        md.append("## Only samples with an OpenAI call\n")
        md.append(table(llm) + "\n")
        md.append(f"{len(nollm)} sample(s) had no LLM call (calm, no-swap verdict), so they are left out of this table.\n")
    cost = reserves_cost(bench)
    if cost:
        md.append("## What a cycle costs the reactive contract\n")
        md.append(cost + "\n")
    md.append("## Every sample\n")
    md.append("| Run | Epoch | Dir | Score | Swap->verdict s | Verdict->vault s | Swap->vault s | Verdict tx | Vault callback tx |")
    md.append("|---|---|---|---|---|---|---|---|---|")
    for s in valid:
        md.append(
            f"| {s['run'].replace('.log', '')} | {s['epoch']} | {s['direction']} | {s['score']} | "
            f"{fmt(s['swap_to_pub'])} | {fmt(s['pub_to_vault'])} | {fmt(s['swap_to_vault'])} | "
            f"[{s['pub_tx'][:10]}]({BASE_TX}{s['pub_tx']}) | [{s['cb_tx'][:10]}]({BASE_TX}{s['cb_tx']}) |"
        )
    if invalid:
        md.append("\n## Samples that could not be parsed (excluded)\n")
        for s in invalid:
            md.append(f"- {s['run']} epoch {s['epoch']}: {s['why']}")
    open(os.path.join(bench, "RESULTS.md"), "w").write("\n".join(md) + "\n")

    print(f"{len(valid)} samples from {len(logs)} runs ({len(invalid)} excluded)")
    print(table(valid))
    print(f"\nwritten: {bench}/RESULTS.md and {bench}/results.json")


if __name__ == "__main__":
    main()
