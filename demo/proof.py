#!/usr/bin/env python3
"""Evidence for one AI verdict (epoch): swap -> AI -> publish -> Reactive (Lasna) -> vault callback.

  python3 demo/proof.py            # list verdicts
  python3 demo/proof.py 6          # evidence for epoch 6

Needs the project .env (addresses, RPCs, G_REACTIVE_ADDRESS) and `cast` on PATH.
Timestamps are whole seconds. Lasna and Base clocks are separate, so only Base-to-Base
differences are exact; the Lasna line is shown for the tx hash and ordering.
"""
import json, os, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHUNK = 190  # public Base RPC caps eth_getLogs at 200 blocks


def load_env():
    for line in (ROOT / ".env").read_text().splitlines():
        line = line.strip().removeprefix("export ").strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"').strip("'")
        if v:
            os.environ[k.strip()] = v  # later line wins, empty ignored (same as bash)


def cast(*args):
    return subprocess.run(["cast", *args], capture_output=True, text=True, check=True).stdout.strip()


def num(x):
    return int(x, 16) if isinstance(x, str) and x.startswith("0x") else int(x)


def logs(addr, lo, hi, rpc, sig=None):
    a = ["logs", "--address", addr, "--from-block", str(lo), "--to-block", str(hi), "--rpc-url", rpc, "--json"]
    if sig:
        a.insert(1, sig)
    out = cast(*a)
    return json.loads(out) if out else []


def ts(block, rpc):
    return int(cast("block", str(block), "--field", "timestamp", "--rpc-url", rpc))


def epoch_topic(n):
    return "0x" + format(n, "064x")


def find_verdict(epoch):
    for line in (ROOT / "ai" / "verdicts.jsonl").read_text().splitlines():
        d = json.loads(line)
        if d.get("epoch") == epoch:
            return d
    sys.exit(f"epoch {epoch} not in ai/verdicts.jsonl")


def list_verdicts():
    print("epoch  time(UTC)            score  why")
    for line in (ROOT / "ai" / "verdicts.jsonl").read_text().splitlines():
        d = json.loads(line)
        print(f"{d.get('epoch'):<6} {d['time'][:19]}  {d['finalScore']:<5}  {d['why']}")
    print("\nRun:  python3 demo/proof.py <epoch>")


def main():
    if len(sys.argv) < 2:
        return list_verdicts()
    epoch = int(sys.argv[1])
    load_env()
    base, lasna = os.environ["BASE_SEPOLIA_RPC"], os.environ["LASNA_RPC"]
    pool, vault, reactive = os.environ["POOL_ADDRESS"], os.environ["VAULT_ADDRESS"], os.environ["G_REACTIVE_ADDRESS"]

    v = find_verdict(epoch)
    pub_block, pub_tx = v["block"], v["txHash"]
    pub_ts = ts(pub_block, base)

    # 1. the swap that triggered this verdict: latest pool Swap at or before the publish block
    swap_topic = cast("keccak", "Swap(address,address,bool,uint256,uint256,uint256)").lower()
    swap = None
    hi = pub_block
    for _ in range(4):
        lo = max(0, hi - CHUNK)
        sw = [l for l in logs(pool, lo, hi, base) if l["topics"][0].lower() == swap_topic]
        if sw:
            swap = sorted(sw, key=lambda l: (num(l["blockNumber"]), num(l.get("logIndex", 0))))[-1]
            break
        hi = lo - 1
    swap_block = num(swap["blockNumber"]) if swap else None
    swap_ts = ts(swap_block, base) if swap else None

    # 2. vault callback event for this epoch (DeRisked / ReRisked / CallbackIgnored)
    names = {
        cast("keccak", "DeRisked(uint256,uint256,uint256,uint256)").lower(): "DeRisked",
        cast("keccak", "ReRisked(uint256,uint256,uint256,uint256)").lower(): "ReRisked",
        cast("keccak", "CallbackIgnored(uint256,uint8)").lower(): "CallbackIgnored",
    }
    cb = None
    for l in logs(vault, pub_block, pub_block + CHUNK, base):
        if l["topics"][0].lower() in names and len(l["topics"]) > 1 and num(l["topics"][1]) == epoch:
            cb = l
            break

    # 3. Reactive Lasna ActionRequested for this epoch (search recent history)
    head = int(cast("block-number", "--rpc-url", lasna))
    act_topic = cast("keccak", "ActionRequested(uint256,uint8,bool)").lower()
    act = None
    for l in logs(reactive, max(0, head - 5000), head, lasna):
        if l["topics"][0].lower() == act_topic and num(l["topics"][1]) == epoch:
            act = l
    act_ts = ts(num(act["blockNumber"]), lasna) if act else None

    print(f"=== Evidence for epoch {epoch} (score {v['finalScore']}, rule {v['ruleScore']}, "
          f"LLM {v['llm']['score'] if v.get('llm') else 'n/a'} {v['llm']['model'] if v.get('llm') else ''})")
    print(f"reason: {v['reasonText']}")
    print(f"reasonHash: {v['reasonHash']}")
    print()
    if swap:
        print(f"trigger swap    Base block {swap_block}  t={swap_ts}  tx {swap['transactionHash']}")
    print(f"publishRisk     Base block {pub_block}  t={pub_ts}  tx {pub_tx}")
    if act:
        print(f"ActionRequested Lasna block {num(act['blockNumber'])}  t={act_ts}  tx {act['transactionHash']}")
    else:
        print("ActionRequested Lasna: none for this epoch (reactive skipped it: hysteresis/cooldown/stale)")
    if cb:
        cb_block = num(cb["blockNumber"])
        cb_ts = ts(cb_block, base)
        print(f"{names[cb['topics'][0].lower()]:<15} Base block {cb_block}  t={cb_ts}  tx {cb['transactionHash']}")
        print()
        print(f"publish -> vault callback : {cb_ts - pub_ts} s   (Base to Lasna to Base)")
        if swap:
            print(f"swap -> publish           : {pub_ts - swap_ts} s   (detection + LLM + tx)")
            print(f"swap -> vault callback    : {cb_ts - swap_ts} s   (whole loop, LLM included)")
    else:
        print("vault callback: none for this epoch (no action was needed or reactive skipped it)")


if __name__ == "__main__":
    main()
