#!/usr/bin/env bash
# Bring the pool price back to ~1.0 by sizing one swap automatically.
# Run it with the AI service STOPPED (Ctrl+C in the AI terminal), otherwise the AI reads the move as a crash/recovery.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
PW="${PASSFILE:-$HOME/.guardian-pw}"
[ -f "$PW" ] || { echo "Missing $PW (see header of demo/staged-crash.sh)"; exit 1; }

RV=$(cast call "$POOL_ADDRESS" "reserveVol()(uint256)" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}')
RS=$(cast call "$POOL_ADDRESS" "reserveStable()(uint256)" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}')

OUT=$(python3 - "$RV" "$RS" <<'PY'
import sys, math
v, s = int(sys.argv[1]), int(sys.argv[2])
t = math.isqrt(v * s)                      # reserve of each side when the price is exactly 1.0
if abs(s / v - 1) < 0.03:
    print("none 0")
elif s > v:                                # price > 1: sell gVOL into the pool
    print("sell", int((t - v) / 0.997))
else:                                      # price < 1: buy gVOL with gUSD
    print("buy", int((t - s) / 0.997))
PY
)
SIDE=${OUT%% *}; AMT=${OUT##* }
echo "pool: price $(python3 -c "print(round($RS/$RV,4))")  ->  action: $SIDE ${AMT} wei"

case "$SIDE" in
  none) echo "Price already within 3% of 1.0. Nothing to do." ;;
  sell) DUMP_VOL_WEI="$AMT" forge script script/Guardian.s.sol:CrashPool \
          --rpc-url "$BASE_SEPOLIA_RPC" --account "$ACCOUNT" --password-file "$PW" --broadcast 2>&1 | grep -E "Error|revert|price after" ;;
  buy)  RECOVER_STABLE_WEI="$AMT" forge script script/Guardian.s.sol:RecoverPool \
          --rpc-url "$BASE_SEPOLIA_RPC" --account "$ACCOUNT" --password-file "$PW" --broadcast 2>&1 | grep -E "Error|revert|price after" ;;
esac
