#!/usr/bin/env bash
# The whole story in one command, with on-screen narration. Made for screen recording.
#
# Before you start:
#   1. AI terminal running in a split pane:  cd ai && npm start
#   2. pool near 1.0 and vault risk-on (run demo/reset-pool.sh with the AI stopped if not)
#   3. ~/.guardian-pw exists (see demo/staged-crash.sh header). Delete it after.
# Then:  demo/run-demo.sh        (STEPS=4 GAP=12 by default; takes ~4-5 minutes, cut/speed up in the video)
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
PW="${PASSFILE:-$HOME/.guardian-pw}"
[ -f "$PW" ] || { echo "Missing $PW"; exit 1; }
STEPS="${STEPS:-4}"; GAP="${GAP:-12}"; DUMP="${DUMP_VOL_WEI:-1000000000000000000000}"
RPC="$BASE_SEPOLIA_RPC"
say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
riskoff() { cast call "$VAULT_ADDRESS" "riskOff()(bool)" --rpc-url "$RPC"; }
wait_riskoff() {   # wait_riskoff <true|false> <timeout-seconds>
  local want=$1 limit=$2 t0=$SECONDS
  while [ "$(riskoff)" != "$want" ]; do
    [ $((SECONDS - t0)) -ge "$limit" ] && { echo "timed out waiting for riskOff=$want (is the AI service running?)"; return 1; }
    printf '\r   waiting for the vault... %ss ' $((SECONDS - t0)); sleep 2
  done
  printf '\r   vault riskOff=%s after %ss          \n' "$want" $((SECONDS - t0))
}

START=$(date -u +%s)
SEED_VOL=$(cast call "$VAULT_ADDRESS" "holdings()(uint256,uint256)" --rpc-url "$RPC" | awk 'NR==1{printf "%.2f", $1/1e18}')
export SEED_VOL

say "1/5  Vault today: holds $SEED_VOL gVOL (the volatile token), pool price near 1.0"
demo/status.sh
sleep 3

say "2/5  Market crash: $STEPS sells of $(python3 -c "print(int('$DUMP')//10**18)") gVOL, ${GAP}s apart. Watch the AI terminal."
T_CRASH=$SECONDS
STEPS=$STEPS GAP=$GAP DUMP_VOL_WEI=$DUMP demo/staged-crash.sh

say "3/5  Did the AI + Reactive Network protect the vault?"
wait_riskoff true 120
DERISK_AT=$SECONDS
demo/status.sh

say "4/5  Recovery: price goes back to ~1.0 (waiting out the 60 s cooldown first)"
while [ $((SECONDS - DERISK_AT)) -lt 65 ]; do printf '\r   cooldown %ss ' $((65 - (SECONDS - DERISK_AT))); sleep 2; done; echo
demo/reset-pool.sh
wait_riskoff false 180
demo/status.sh

say "5/5  On-chain evidence for this run"
python3 - "$START" <<'PY' > /tmp/.guardian-epochs
import json, sys, datetime, os
start = int(sys.argv[1]); de = re = None
for line in open(os.environ.get("VERDICT_LOG", "ai/verdicts.jsonl")):
    d = json.loads(line)
    t = datetime.datetime.fromisoformat(d["time"].replace("Z", "+00:00")).timestamp()
    if t < start: continue
    if de is None and "de-risk" in d["why"]: de = d["epoch"]
    if de is not None and re is None and "re-risk" in d["why"]: re = d["epoch"]
print(de or "", re or "")
PY
read -r DE RE < /tmp/.guardian-epochs || true
[ -n "${DE:-}" ] && demo/proof.sh "$DE" || echo "(de-risk verdict not found in ai/verdicts.jsonl)"
[ -n "${RE:-}" ] && { echo; demo/proof.sh "$RE"; } || echo "(re-risk verdict not found)"
say "Done. Full AI reasoning for every verdict: ai/verdicts.jsonl"
