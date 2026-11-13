#!/usr/bin/env bash
# Snapshot: pool price, vault state, and what the vault is worth vs. simply holding.
set -euo pipefail
cd "$(dirname "$0")/.."
source .env
SEED_VOL="${SEED_VOL:-100}"   # gVOL originally deposited

PRICE=$(cast call "$POOL_ADDRESS" "priceE18()(uint256)" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}')
RISKOFF=$(cast call "$VAULT_ADDRESS" "riskOff()(bool)" --rpc-url "$BASE_SEPOLIA_RPC")
mapfile -t H < <(cast call "$VAULT_ADDRESS" "holdings()(uint256,uint256)" --rpc-url "$BASE_SEPOLIA_RPC" | awk '{print $1}')
VOL="${H[0]}"; STABLE="${H[1]}"

python3 - "$PRICE" "$RISKOFF" "$VOL" "$STABLE" "$SEED_VOL" <<'PY'
import sys
price, riskoff, vol, stable, seed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
p = int(price) / 1e18
v, s = vol / 1e18, stable / 1e18
value = v * p + s
hold = seed * p
print(f"pool price        : {p:.4f} gUSD per gVOL")
print(f"vault riskOff     : {riskoff}")
print(f"vault holdings    : {v:.4f} gVOL + {s:.4f} gUSD")
print(f"vault value       : {value:.2f} gUSD (at current price)")
print(f"if just held {seed:g} gVOL: {hold:.2f} gUSD")
print(f"difference        : {value - hold:+.2f} gUSD")
PY
