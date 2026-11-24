# v3: the watchdog (what happens when the AI does not answer)

In v2 every action starts from an AI verdict. If the AI service is down, late, or confidently wrong, a crash is not answered. v3 adds a second path that does not need the AI.

```
            AI path (unchanged)                        watchdog path (new)
 Swap ──► AI service ──► RiskOracle ──► Reactive      Swap ──► Reactive (subscribed to the pool directly)
                              RiskUpdated │                       │ price <= stop level for GRACE seconds,
                                          ▼                       │ and the AI path has not moved the vault
                                   vault.deRisk()                 ▼
                                   (re-checks the oracle)   vault.breakerDeRisk()
                                                            (re-reads the pool itself)
```

## Rules

| Rule | Where |
|---|---|
| The Reactive contract subscribes to the pool's `Swap` event and remembers the last price. | `GuardianReactiveV3.react` |
| Stop level = `entryPrice × (10000 − BREAKER_BPS) / 10000`. Default `BREAKER_BPS = 4000`, so 40% below entry. | `stopPriceE18()` |
| Price at or below the stop level starts a grace timer (`breachSince`, event `BreachSeen`). Price back above it clears the timer (`BreachCleared`). | `_checkBreaker` |
| The AI gets the first chance. A verdict is handled before the watchdog check in the same `react` call, and a de-risk by the AI path resets the timer. | `react` order |
| Only if the timer has run for `GRACE` seconds (default 30) and the vault is still risk-on does it trip: `BreakerTripped`, callback `breakerDeRisk`. | `_checkBreaker` |
| Entry price = the pool price when the vault last went risk-on (set at deploy and on every AI re-risk). | `_onVerdict`, vault `reRisk` |
| Re-risk is never done by the watchdog. It stays AI-driven and oracle-checked. | design |

## Why the vault can trust it less than you might expect

The vault does not take the price or the stop level from the callback. `breakerDeRisk(reactive, seq)`:

1. is callable only by the Reactive Network callback proxy, for this vault's Reactive contract (same checks as `deRisk`);
2. re-reads the pool price itself and compares it with the vault's own `entryPriceE18` and its own `BREAKER_BPS`;
3. refuses unless the price really is at or below the stop level: it emits `BreakerRejected(seq, reason, price)` (a visible, successful transaction, no sale) instead of reverting. Reasons: 1 watchdog disabled, 2 already risk-off, 3 price not at or below the stop, 4 replay or old sequence number;
4. on success sells the volatile token and emits `BreakerDeRisked(seq, entry, price, volSold, stableReceived)`.

So a wrong or malicious Reactive belief cannot sell the vault while the pool price is healthy. A test fuzzes this (`testFuzz_breakerNeverSellsAbovePrice`), and three mutations (inverted price check, skipped grace period, watchdog running while risk-off) were each caught by the suite.

## Limitations (read these before relying on it)

- **It needs something to wake it.** Reactive contracts run on events. After the grace period no event arrives by itself, so the watchdog trips on the next pool `Swap`, the next oracle verdict, or (optionally) a Cron tick. On a busy pool the next swap comes quickly. The demo sends one tiny swap (`NudgePool`).
- **Cron is optional and unverified here.** `CRON_TOPIC0` is 0 (off) by default. A Cron subscription is billed per tick against the Reactive contract's reserves, and I did not verify it on Lasna. Leave it off unless you have tested it.
- **Reactive's belief can drift.** If a callback is rejected on the destination chain (including a `BreakerRejected`), `riskOff` on the Reactive side can disagree with the vault. This exists in v2 too. `overrideRiskState(bool)` (owner only) realigns it.
- **It is a stop-loss, not a prediction.** It sells after a large drop. It does not avoid the drop, and in a pool with real slippage it sells at the bad price.
- **Mock market.** Testnet, mock tokens, mock pool. No mainnet claim.

## Deploy (v3 next to v2; v2 stays live as a fallback)

```bash
# 1. market (Base Sepolia): tokens + pool + oracle. Update .env with the printed addresses.
forge script script/Guardian.s.sol:DeployMarket --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast

# 2. Reactive contract v3 (Lasna). Needs ORACLE_ADDRESS and POOL_ADDRESS in .env.
forge script script/GuardianV3.s.sol:DeployGuardianReactiveV3 --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
#    -> put G_REACTIVE_ADDRESS in .env

# 3. vault v3 (Base Sepolia)
forge script script/GuardianV3.s.sol:DeployVaultV3 --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
#    -> put VAULT_ADDRESS in .env

# 4. link and seed (unchanged scripts)
forge script script/Guardian.s.sol:LinkVault --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
forge script script/Guardian.s.sol:SeedVault --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast

# 5. top up the Reactive contract on Lasna (a plain transfer does NOT work; use depositTo)
cast send 0x8888888888888888888888888888888888888888 "depositTo(address)" $G_REACTIVE_ADDRESS \
  --value 0.5ether --rpc-url $LASNA_RPC --account $ACCOUNT
```

Check `reserves($G_REACTIVE_ADDRESS)` is above 0 and `debt($G_REACTIVE_ADDRESS)` is 0 on the system contract before any demo. With debt above 0 Reactive silently stops processing events.

Settings (env, all optional): `BREAKER_BPS` (4000; 0 turns the watchdog off), `GRACE_SECONDS` (30), `ENTRY_PRICE_E18` (1e18), `CRON_TOPIC0` (0). Keep `BREAKER_BPS` equal on the Reactive contract and the vault.

## Demo: the AI is down and the vault still protects itself

1. Stop the AI service (Ctrl+C).
2. Make sure the vault is risk-on and the pool price is near 1.0.
3. `demo/watchdog.sh`. It crashes the pool, waits for Reactive to log `BreachSeen`, waits out the grace period, sends the wake-up swap, polls `riskOff()`, and prints the timeline with explorer links. The log is saved in `watchdog/run-NNN.log`.
4. Restore the price (`RecoverPool` or `demo/reset-pool.sh`), start the AI service again. Its next calm verdict re-risks the vault.

Commit the run log (`watchdog/run-001.log`) as evidence, the same way as the `bench*/` folders.
