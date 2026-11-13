#!/usr/bin/env bash
# Submission evidence for one AI verdict: crash swap -> AI publish -> Lasna reaction -> vault callback.
# Usage:  demo/proof.sh <epoch>          (epoch numbers are in ai/verdicts.jsonl / the AI terminal)
#         demo/proof.sh 6 | tee -a NOTES.md
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
EPOCH="${1:?usage: demo/proof.sh <epoch>}"
LOG="${VERDICT_LOG:-ai/verdicts.jsonl}"
B="--rpc-url $BASE_SEPOLIA_RPC"
L="--rpc-url $LASNA_RPC"
EPH=$(printf '0x%064x' "$EPOCH")
SWAP_SIG="Swap(address indexed,address indexed,bool,uint256,uint256,uint256)"

# 1. our own record of the verdict
REC=$(python3 - "$EPOCH" "$LOG" <<'PY'
import sys, json
ep = int(sys.argv[1])
for line in open(sys.argv[2]):
    d = json.loads(line)
    if d.get("epoch") == ep:
        print(d["txHash"], d["block"], d["finalScore"], d.get("llm", {}) and d["llm"].get("model", ""), sep="\t")
        break
else:
    sys.exit(f"epoch {ep} not found in {sys.argv[2]}")
PY
)
PUBTX=$(echo "$REC" | cut -f1); PUBBLK=$(echo "$REC" | cut -f2); SCORE=$(echo "$REC" | cut -f3); MODEL=$(echo "$REC" | cut -f4)
REASON=$(python3 - "$EPOCH" "$LOG" <<'PY'
import sys, json
for line in open(sys.argv[2]):
    d = json.loads(line)
    if d.get("epoch") == int(sys.argv[1]):
        print(d["reasonText"]); break
PY
)

# pick <epoch-hex|last>: read a `cast logs --json` array on stdin, print "<txHash> <blockNumber>" or nothing
pick() {
python3 -c '
import sys, json
mode = sys.argv[1]
try:
    logs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
def num(x):
    return int(x, 16) if isinstance(x, str) and x.startswith("0x") else int(x)
if mode != "last":
    logs = [l for l in logs if len(l.get("topics", [])) > 1 and l["topics"][1].lower() == mode.lower()]
if not logs:
    sys.exit(0)
logs.sort(key=lambda l: (num(l["blockNumber"]), num(l.get("logIndex", 0))))
l = logs[-1] if mode == "last" else logs[0]
print(l["transactionHash"], num(l["blockNumber"]))
' "$1"
}

ts() { cast block "$1" --field timestamp "${@:2}"; }

PUBTS=$(ts "$PUBBLK" $B)

# 2. the swap that triggered the AI: last pool swap before the publish (cast logs is capped at ~200 blocks per call)
SWAP=""
for i in 0 1 2 3 4 5; do
  TO=$((PUBBLK - i*190)); FROM=$((TO - 189))
  SWAP=$(cast logs --address "$POOL_ADDRESS" "$SWAP_SIG" --from-block $FROM --to-block $TO --json $B | pick last) || true
  [ -n "$SWAP" ] && break
done

# 3. vault callback (DeRisked or ReRisked with this epoch)
CB=""
for i in 0 1 2 3; do
  FROM=$((PUBBLK + i*190)); TO=$((FROM + 189))
  for SIG in "DeRisked(uint256 indexed,uint256,uint256,uint256)" "ReRisked(uint256 indexed,uint256,uint256,uint256)"; do
    CB=$(cast logs --address "$VAULT_ADDRESS" "$SIG" --from-block $FROM --to-block $TO --json $B | pick "$EPH") || true
    [ -n "$CB" ] && { KIND="${SIG%%(*}"; break 2; }
  done
done

# 4. Lasna reaction. The Lasna RPC cannot binary-search from block 1 (cast find-block fails), so estimate the
#    block at the publish time from the current head and the recent block rate, refine, then scan around it.
lasna_block_at() {
  local want=$1 head hts b2 t2 est t i
  head=$(cast block-number $L); hts=$(ts "$head" $L)
  b2=$((head - 2000)); t2=$(ts "$b2" $L)
  est=$(python3 -c "r=2000/max(1,$hts-$t2); print(max(1,int($head-($hts-$want)*r)))")
  for i in 1 2 3; do
    t=$(ts "$est" $L)
    est=$(python3 -c "r=2000/max(1,$hts-$t2); print(max(1,int($est+($want-$t)*r)))")
  done
  echo "$est"
}
RX=""
if LB=$(lasna_block_at "$PUBTS" 2>/dev/null); then
  RX=$(cast logs --address "$G_REACTIVE_ADDRESS" "ActionRequested(uint256 indexed,uint8,bool)" --from-block $((LB - 60)) --to-block $((LB + 180)) --json $L 2>/dev/null | pick "$EPH") || true
fi

echo "## Proof for epoch $EPOCH (score $SCORE, model ${MODEL:-n/a})"
echo "Reason: $REASON"
echo
if [ -n "$SWAP" ]; then
  S_TX=${SWAP% *}; S_BLK=${SWAP#* }; S_TS=$(ts "$S_BLK" $B)
  echo "Trigger swap (Base block $S_BLK, t=$S_TS): $S_TX"
fi
echo "AI publishRisk (Base block $PUBBLK, t=$PUBTS): $PUBTX"
if [ -n "$RX" ]; then
  R_TX=${RX% *}; R_BLK=${RX#* }; R_TS=$(ts "$R_BLK" $L)
  echo "Reactive ActionRequested (Lasna block $R_BLK, t=$R_TS): $R_TX"
else
  echo "Reactive ActionRequested (Lasna): none found for this epoch (the reactive contract may have skipped it: hysteresis, cooldown or stale; see its Skipped events)"
fi
if [ -n "$CB" ]; then
  C_TX=${CB% *}; C_BLK=${CB#* }; C_TS=$(ts "$C_BLK" $B)
  echo "Vault $KIND callback (Base block $C_BLK, t=$C_TS): $C_TX"
  echo
  [ -n "$SWAP" ] && echo "swap -> AI publish : $((PUBTS - S_TS)) s (includes polling, features, OpenAI call, tx confirmation)"
  echo "publish -> vault   : $((C_TS - PUBTS)) s (oracle event -> Lasna -> callback)"
  [ -n "$SWAP" ] && echo "swap -> vault moved: $((C_TS - S_TS)) s end to end"
  echo "(timestamps are Base block times, 1 s resolution)"
else
  echo "Vault callback: not found within 760 blocks of the publish (no action was requested for this epoch?)"
fi
