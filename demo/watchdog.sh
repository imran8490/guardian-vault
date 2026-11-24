#!/usr/bin/env bash
# Watchdog demo (v3): the AI service is DOWN, the pool crashes, and the vault still protects itself.
#
#   crash swap -> Reactive sees the Swap event (breach seen, grace timer starts)
#              -> grace period passes with no AI verdict
#              -> a later event wakes the watchdog (Cron tick, or the small NudgePool swap below)
#              -> Reactive requests breakerDeRisk -> the vault re-reads the pool itself and sells
#
# Before you start:
#   1. STOP the AI service (Ctrl+C in its terminal). The point of this run is that nobody scores the crash.
#   2. .env points at the v3 deployment (G_REACTIVE_ADDRESS is a GuardianReactiveV3, VAULT_ADDRESS a GuardianVaultV3).
#   3. Pool price near 1.0 and the vault risk-on. ~/.guardian-pw exists (see demo/staged-crash.sh header).
# Usage:
#   demo/watchdog.sh            # one run, log in watchdog/run-NNN.log
#   NUDGE=0 demo/watchdog.sh    # you deployed with a Cron topic: do not send the wake-up swap, wait for the tick
# Afterwards: restore the price (RecoverPool or demo/reset-pool.sh) and start the AI service; its next calm
# verdict re-risks the vault (re-risk is always AI-driven and oracle-checked).
set -uo pipefail
cd "$(dirname "$0")/.."
source .env

OUT="${WATCHDOG_DIR:-watchdog}"
PW="${PASSFILE:-$HOME/.guardian-pw}"
DUMP="${DUMP_VOL_WEI:-5000000000000000000000}"   # 5000 gVOL in one sell: price falls far below the 40% stop
NUDGE="${NUDGE:-1}"
SYS=0x8888888888888888888888888888888888888888
mkdir -p "$OUT"
[ -f "$PW" ] || { echo "Missing $PW (see header of demo/staged-crash.sh)"; exit 1; }
N=$(( $(ls "$OUT"/run-*.log 2>/dev/null | wc -l) + 1 ))
LOGF="$OUT/run-$(printf '%03d' "$N").log"
exec > >(tee "$LOGF") 2>&1

B=(--rpc-url "$BASE_SEPOLIA_RPC")
L=(--rpc-url "$LASNA_RPC")
now() { date +%s; }
ts()  { date +%T; }
riskoff() { cast call "$VAULT_ADDRESS" "riskOff()(bool)" "${B[@]}" 2>/dev/null; }
price()   { cast call "$POOL_ADDRESS" "priceE18()(uint256)" "${B[@]}" 2>/dev/null | awk '{print $1}'; }
breach()  { cast call "$G_REACTIVE_ADDRESS" "breachSince()(uint256)" "${L[@]}" 2>/dev/null | awk '{print $1}'; }

echo "Watchdog demo run $N  ($(date))"
GRACE=$(cast call "$G_REACTIVE_ADDRESS" "GRACE()(uint256)" "${L[@]}" 2>/dev/null | awk '{print $1}')
BPS=$(cast call "$G_REACTIVE_ADDRESS" "BREAKER_BPS()(uint256)" "${L[@]}" 2>/dev/null | awk '{print $1}')
STOP=$(cast call "$G_REACTIVE_ADDRESS" "stopPriceE18()(uint256)" "${L[@]}" 2>/dev/null | awk '{print $1}')
VBPS=$(cast call "$VAULT_ADDRESS" "BREAKER_BPS()(uint256)" "${B[@]}" 2>/dev/null | awk '{print $1}')
if [ -z "${GRACE:-}" ] || [ -z "${BPS:-}" ]; then
  echo "G_REACTIVE_ADDRESS does not look like a GuardianReactiveV3 (GRACE()/BREAKER_BPS() not readable). Check .env and the Lasna RPC."; exit 1
fi
echo "Reactive: stop level ${BPS} bps below entry (price <= $(python3 -c "print(int('$STOP')/1e18)")), grace ${GRACE}s. Vault stop level: ${VBPS} bps."

RO=$(riskoff || echo unknown)
[ "$RO" = "false" ] || { echo "Vault riskOff is '$RO'. Bring it back to risk-on first."; exit 1; }
P=$(price || echo 0)
python3 - "$P" <<'PY' || { echo "Pool price is not near 1.0. Reset the pool first (demo/reset-pool.sh)."; exit 1; }
import sys
p = int(sys.argv[1]) / 1e18
sys.exit(0 if 0.9 <= p <= 1.1 else 1)
PY
RES=$(cast call "$SYS" "reserves(address)(uint256)" "$G_REACTIVE_ADDRESS" "${L[@]}" 2>/dev/null | awk '{print $1}')
DEBT=$(cast call "$SYS" "debt(address)(uint256)" "$G_REACTIVE_ADDRESS" "${L[@]}" 2>/dev/null | awk '{print $1}')
python3 - "${RES:-}" "${DEBT:-}" <<'PY' || { echo "Fix reserves first: cast send $SYS \"depositTo(address)\" \$G_REACTIVE_ADDRESS --value 0.5ether ... (a plain transfer does not help)"; exit 1; }
import sys
if not sys.argv[1] or not sys.argv[2]:
    print("    could not read reserves/debt from the Lasna RPC (try again in a minute)"); sys.exit(1)
res, debt = int(sys.argv[1]) / 1e18, int(sys.argv[2]) / 1e18
print(f"    reactive reserves {res:.4f} REACT, debt {debt:.4f}")
sys.exit(0 if debt == 0 and res >= 0.05 else 1)
PY
echo "REMINDER: the AI service must be stopped for this run."

START_BLK=$(cast block-number "${B[@]}")
T0=$(now)
echo
echo "[$(ts)] crash: one sell of $(python3 -c "print(int('$DUMP')/1e18)") gVOL"
DUMP_VOL_WEI="$DUMP" forge script script/Guardian.s.sol:CrashPool \
  --rpc-url "$BASE_SEPOLIA_RPC" --account "$ACCOUNT" --password-file "$PW" --broadcast 2>&1 \
  | grep -E "Error|revert|price after|Hash:" || true
T_CRASH=$(now)

echo "[$(ts)] waiting for Reactive to see the Swap event (breachSince > 0) ..."
T_BREACH=""
for i in $(seq 1 45); do
  BS=$(breach || true)
  if [ -n "${BS:-}" ] && [ "$BS" != "0" ]; then T_BREACH=$(now); echo "[$(ts)] breach seen on Lasna after $((T_BREACH - T_CRASH))s (grace timer started at unix $BS)"; break; fi
  sleep 2
done
[ -n "$T_BREACH" ] || echo "[$(ts)] breachSince still 0 after 90s: Reactive has not processed the Swap yet (check reserves/debt). Continuing anyway."

WAIT=$(( GRACE + 3 ))
echo "[$(ts)] the AI service is silent; waiting ${WAIT}s for the grace period to pass ..."
sleep "$WAIT"

if [ "$NUDGE" = "1" ]; then
  echo "[$(ts)] wake-up: a 1 gVOL swap (any later Swap or oracle event does the same job as a Cron tick)"
  forge script script/GuardianV3.s.sol:NudgePool \
    --rpc-url "$BASE_SEPOLIA_RPC" --account "$ACCOUNT" --password-file "$PW" --broadcast 2>&1 \
    | grep -E "Error|revert|price after" || true
else
  echo "[$(ts)] NUDGE=0: waiting for the Cron tick ..."
fi
T_WAKE=$(now)

echo "[$(ts)] polling the vault ..."
DONE=""
for i in $(seq 1 60); do
  if [ "$(riskoff || echo unknown)" = "true" ]; then DONE=$(now); break; fi
  sleep 2
done

echo
if [ -z "$DONE" ]; then
  echo "RESULT: vault did NOT de-risk within 120s of the wake-up. See: demo/status.sh, Lasna reserves/debt, and the Reactive events."
  exit 2
fi
echo "RESULT: vault is risk-off with no AI verdict at all."
echo "  crash -> breach seen on Lasna : ${T_BREACH:+$((T_BREACH - T_CRASH))s}"
echo "  grace period                  : ${GRACE}s (configured)"
echo "  wake-up -> vault de-risked    : $((DONE - T_WAKE))s"
echo "  total, crash -> de-risked     : $((DONE - T_CRASH))s"
echo "  pool price now                : $(python3 -c "print(int('$(price)')/1e18)")"

echo
echo "Evidence (best effort, the Lasna RPC can be flaky):"
cast logs --from-block "$START_BLK" --address "$VAULT_ADDRESS" \
  "BreakerDeRisked(uint256,uint256,uint256,uint256,uint256)" "${B[@]}" --json 2>/dev/null \
  | python3 -c '
import sys, json
try:
    for l in json.load(sys.stdin):
        print("  vault BreakerDeRisked tx: https://sepolia.basescan.org/tx/" + l["transactionHash"])
except Exception:
    print("  (could not read vault logs)")'
for try in 1 2 3; do
  OUTJ=$(cast logs --from-block 1 --address "$G_REACTIVE_ADDRESS" \
    "BreakerTripped(uint256,uint256,uint256,uint256)" "${L[@]}" --json 2>/dev/null) && break
  sleep 5
done
echo "${OUTJ:-[]}" | python3 -c '
import sys, json
try:
    for l in json.load(sys.stdin)[-1:]:
        print("  Lasna BreakerTripped tx:  https://lasna.reactscan.net/tx/" + l["transactionHash"])
except Exception:
    print("  (could not read Lasna logs; look the contract up on https://lasna.reactscan.net)")'
echo "Log saved to $LOGF"
