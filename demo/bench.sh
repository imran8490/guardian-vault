#!/usr/bin/env bash
# Latency benchmark. Repeats the full demo cycle N times and aggregates the proof timings:
#   crash (staged sells) -> AI verdict -> Lasna reaction -> vault de-risk
#   recovery swap        -> AI verdict -> Lasna reaction -> vault re-risk
# Each cycle is exactly demo/run-demo.sh (so the numbers come from the same flow as the demo video),
# its output is kept in bench/run-NNN.log, and demo/bench_stats.py turns the logs into
# bench/RESULTS.md + bench/results.json (percentiles + every sample with its tx hashes).
#
# Before you start (same as demo/run-demo.sh):
#   1. AI terminal running:  cd ai && npm start       (leave it running for the whole benchmark)
#   2. pool price near 1.0 and the vault risk-on (riskOff=false)
#   3. ~/.guardian-pw exists (see demo/staged-crash.sh header). Delete it when you are done.
# Usage:
#   RUNS=10 demo/bench.sh        # 10 cycles = ~20 samples (10 de-risk + 10 re-risk), roughly 45-60 min
#   RUNS=5  demo/bench.sh        # run again later: new cycles are appended (run-011.log, ...)
#   python3 demo/bench_stats.py  # re-aggregate without running anything on-chain
set -uo pipefail
cd "$(dirname "$0")/.."
source .env

RUNS="${RUNS:-10}"
OUT="${BENCH_DIR:-bench}"
PAUSE="${PAUSE_BETWEEN:-20}"          # seconds between cycles
PW="${PASSFILE:-$HOME/.guardian-pw}"
SYS=0x8888888888888888888888888888888888888888   # Reactive system contract (from reactive-lib-omni AbstractReactive)
mkdir -p "$OUT"

[ -f "$PW" ] || { echo "Missing $PW (see header of demo/staged-crash.sh)"; exit 1; }
[ -f ai/verdicts.jsonl ] || { echo "ai/verdicts.jsonl not found: start the AI service first (cd ai && npm start)"; exit 1; }

riskoff() { cast call "$VAULT_ADDRESS" "riskOff()(bool)" --rpc-url "$BASE_SEPOLIA_RPC"; }
price()   { cast call "$POOL_ADDRESS" "priceE18()(uint256)" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}'; }

START=$(( $(ls "$OUT"/run-*.log 2>/dev/null | wc -l) + 1 ))
FAILS=0
echo "Benchmark: $RUNS cycles, starting at run $START, logs in $OUT/"

for i in $(seq 1 "$RUNS"); do
  n=$((START + i - 1))
  f="$OUT/run-$(printf '%03d' "$n").log"

  RO=$(riskoff 2>/dev/null || echo unknown)
  if [ "$RO" != "false" ]; then
    echo "Vault riskOff is '$RO' before run $n. Bring it back to risk-on first (see docs/SAFETY.md / demo/reset-pool.sh), then re-run."
    break
  fi
  P=$(price 2>/dev/null || echo 0)
  python3 - "$P" <<'PY' || { echo "Pool price is not near 1.0. Run demo/reset-pool.sh (with the AI service stopped), then restart the AI service and re-run."; break; }
import sys
p = int(sys.argv[1]) / 1e18
sys.exit(0 if 0.9 <= p <= 1.1 else 1)
PY

  # The reactive contract pays for its executions out of its RESERVES at the Lasna system contract, and the
  # vault pays for callbacks in ETH. If the reserves run out, debt appears and the network stops serving the
  # contract (events are silently no longer processed). A plain REACT transfer to the contract does NOT help:
  # top up with depositTo (command printed below). So check reserves, debt and the vault's ETH first.
  RES=$(cast call "$SYS" "reserves(address)(uint256)" "$G_REACTIVE_ADDRESS" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}')
  DEBT=$(cast call "$SYS" "debt(address)(uint256)" "$G_REACTIVE_ADDRESS" --rpc-url "$LASNA_RPC" 2>/dev/null | awk '{print $1}')
  VB=$(cast balance "$VAULT_ADDRESS" --rpc-url "$BASE_SEPOLIA_RPC" --ether 2>/dev/null || echo 0)
  printf '%s\t%s\t%s\n' "$n" "${RES:-}" "${DEBT:-}" >> "$OUT/reserves.tsv"
  python3 - "${RES:-}" "${DEBT:-}" "$VB" "${MIN_RESERVES:-0.05}" "${MIN_VAULT_ETH:-0.003}" <<'PY' || { echo "Stopping before run $n. Fix: cast send $SYS \"depositTo(address)\" $G_REACTIVE_ADDRESS --value 1ether --rpc-url \$LASNA_RPC --account \$ACCOUNT --password-file ~/.guardian-pw   (vault low on ETH: send it some Base Sepolia ETH). Override minimums with MIN_RESERVES / MIN_VAULT_ETH."; break; }
import sys
res, debt = sys.argv[1], sys.argv[2]
if not res or not debt:
    print("    could not read reserves/debt from the Lasna RPC (try again in a minute)")
    sys.exit(1)
res, debt = int(res) / 1e18, int(debt) / 1e18
vb, mr, mv = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
print(f"    reactive reserves {res:.4f} REACT (min {mr}), debt {debt:.4f}, vault {vb:.4f} ETH (min {mv})")
ok = True
if debt > 0:
    print("    the reactive contract has DEBT: the network is not serving it"); ok = False
if res < mr:
    print("    reserves are below the minimum"); ok = False
if vb < mv:
    print("    vault ETH (callback gas reserve) is below the minimum"); ok = False
sys.exit(0 if ok else 1)
PY

  echo
  echo "=== run $n  ($i/$RUNS)  $(date +%T)"
  if demo/run-demo.sh >"$f" 2>&1; then
    grep -E "^(swap -> AI publish|publish -> vault|swap -> vault moved)" "$f" | sed 's/^/    /'
  else
    FAILS=$((FAILS + 1))
    echo "    run $n FAILED, see $f (last lines below)"
    tail -n 5 "$f" | sed 's/^/    | /'
    if [ "$FAILS" -ge 2 ]; then echo "Two failed runs in this session, stopping."; break; fi
  fi
  [ "$i" -lt "$RUNS" ] && sleep "$PAUSE"
done

echo
python3 demo/bench_stats.py "$OUT"
