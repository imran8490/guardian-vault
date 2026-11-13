#!/usr/bin/env bash
# Staged crash for the live demo: N sells of DUMP gVOL each, GAP seconds apart.
# The AI service sees the first drops and the vault should de-risk before the crash finishes.
#
# Needs the keystore password without prompting every time. Create it once (testnet wallet only!):
#   printf '%s' 'YOUR_KEYSTORE_PASSWORD' > ~/.guardian-pw && chmod 600 ~/.guardian-pw
# and delete it after the demo:  rm ~/.guardian-pw
set -euo pipefail
cd "$(dirname "$0")/.."
source .env

STEPS="${STEPS:-6}"
GAP="${GAP:-20}"
DUMP="${DUMP_VOL_WEI:-1000000000000000000000}"   # 1000 gVOL per step
PW="${PASSFILE:-$HOME/.guardian-pw}"
[ -f "$PW" ] || { echo "Missing $PW (see header of this script)"; exit 1; }

echo "Staged crash: $STEPS x $(python3 -c "print(int('$DUMP')/1e18)") gVOL, every ${GAP}s"
for i in $(seq 1 "$STEPS"); do
  echo "--- dump $i/$STEPS  ($(date +%T))"
  DUMP_VOL_WEI="$DUMP" forge script script/Guardian.s.sol:CrashPool \
    --rpc-url "$BASE_SEPOLIA_RPC" --account "$ACCOUNT" --password-file "$PW" --broadcast 2>&1 \
    | grep -E "Error|revert|price after|Hash:" || true
  [ "$i" -lt "$STEPS" ] && sleep "$GAP"
done
echo "Done. Watch the AI terminal, then run demo/status.sh"
