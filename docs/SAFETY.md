# Safety evidence: what happens when things go wrong

Every row maps a failure to the safeguard that contains it and to the test that proves it.
Reproduce with one command: `demo/safety-proof.sh` (Foundry + Node 20). The full output of the last run is at the bottom.

## Scope: what this is and is not

- **Testnet only, mock assets.** Base Sepolia (chain 84532) and Reactive Lasna. `gVOL` / `gUSD` are open-mint test tokens and the pool is a small constant-product mock. Nothing here touches mainnet, real liquidity or real funds.
- **Not a mainnet DeFi product.** There is no real-pool adapter, no audit, and the numbers (e.g. +9.24 gUSD versus holding) are illustrative of a reproducible scenario, not a performance claim.
- **What is real:** the Reactive Network loop (Lasna reactive contract subscribed to on-chain events, callbacks delivered to a Base Sepolia contract), the OpenAI call in the loop, and the on-chain transactions. Their hashes are in `NOTES.md` / `EVIDENCE.md`.
- The vault de-risks *after* the first drop, and a full round trip costs money. See "Honest limitations" in the README.

## Threat table

| # | Failure | Safeguard | Where | Test(s) |
|---|---------|-----------|-------|---------|
| 1 | **AI is wrong: invents a crash in a calm market** | Guard band: final score = LLM score clamped to rule score ± 30, so it cannot reach 70 when the rule score is ~0 | `ai/src/features.js` `applyGuard` | `model hallucinates a crash in a calm market => clamped…` |
| 2 | **AI is wrong: ignores an obvious crash** | Same band; a rule score of 100 always yields ≥ 70 | same | `model ignores an obvious crash => clamped above…` |
| 3 | **A wrong / unjustified verdict reaches the vault anyway** (buggy or compromised reactive layer, forged "all clear") | The vault re-reads `RiskOracle` itself; de-risk needs latest score ≥ 70, re-risk needs ≤ 30; otherwise it emits `CallbackRejected` and does not trade | `GuardianVault._verdictJustifies` | `test_wrongVerdict_calmOracleBlocksDeRisk`, `…middleBandBlocksBothDirections`, `…highOracleBlocksReRisk`, `…thresholdsAreInclusive` |
| 4 | **Verdict superseded before the callback lands** | Vault checks the *latest* verdict, so a danger callback cannot sell after a calm verdict arrived | same | `test_supersededVerdict_cannotSellVault` |
| 5 | **OpenAI API failure** (HTTP 5xx, bad key, timeout, garbage / empty output) | One retry, then fall back to the deterministic rule score and mark the verdict `fallback`; the service keeps running | `ai/src/llm.js`, `ai/src/scoring.js` | `API down (HTTP 500 twice)…`, `bad API key (401)…`, `network timeout…`, `model returns garbage / empty content…`, `fallback in a calm market stays calm…` |
| 6 | **No AI verdict at all** (service stopped) | Nothing downstream moves; users can still withdraw | `GuardianReactive` only reacts to oracle events | `test_noAiVerdict_noMovement`, `test_userCanAlwaysWithdraw_evenIfReactiveNeverActs` |
| 7 | **Stale verdict** | Reactive ignores verdicts older than `MAX_AGE`; the vault independently rejects if the oracle's latest verdict is older than `MAX_AGE` | `GuardianReactive.react`, `GuardianVault._verdictJustifies` | `test_staleVerdictIgnored`, `test_verdictExactlyMaxAgeStillValid`, `test_staleOracleVerdict_isRejected`, `test_verdictExactlyMaxAge_stillAccepted` |
| 8 | **Replay / duplicate callback** | Reactive consumes only epochs newer than the last; the vault ignores epochs ≤ `lastActedEpoch` and "already in that state"; a rejected callback does not burn the epoch | both | `test_replayedEpochIgnored`, `test_duplicateAndStaleCallbacksAreIgnored`, `test_rejectedCallbackDoesNotConsumeEpoch` |
| 9 | **Callback epoch from the future / no verdict ever published** | Vault rejects an epoch ahead of the oracle's | `GuardianVault` | `test_futureEpoch_isRejected`, `test_noVerdictEverPublished_rejects` |
| 10 | **Unauthorized signer publishes a verdict** | `publishRisk` reverts unless `msg.sender == signer`; only the owner can rotate the signer; score > 100 reverts | `RiskOracle` | `test_onlySignerCanPublish`, `test_setSignerOnlyOwner`, `test_scoreAbove100Reverts` |
| 11 | **Unauthorized caller moves the vault** | `deRisk` / `reRisk` only via the callback proxy, and only when the injected sender is our reactive contract | `AbstractCallback` modifiers | `test_deRiskRejectsNonProxy`, `test_deRiskRejectsWrongReactiveSender`, `test_reRiskRejectsNonProxyAndWrongSender` |
| 12 | **Flip-flopping / whipsaw** | Hysteresis 70 / 30 and a 60 s cooldown | `GuardianReactive` | `test_hysteresis_middleBandDoesNotFlipBack`, `test_cooldownBlocksQuickFlipThenAllowsLater` |
| 13 | **Bad execution price** | Slippage guard against pool spot price; failure reverts and leaves state untouched | `GuardianVault` | `test_slippageGuardBlocksBadTrade` |
| 14 | **Funds locked** | `withdraw()` has no dependency on AI, oracle or Reactive | `GuardianVault` | `test_userCanAlwaysWithdraw_evenIfReactiveNeverActs`, `test_withdrawWhileRiskOffPaysStable` |

### Known trade-off of the independent check

When the vault rejects a callback, the Reactive contract has already flipped its own `riskOff` belief. The failure is on the safe side (the vault simply stays where it was), and the owner can realign with `overrideRiskState`; a later calm verdict brings the two back in step. A rejected callback is a successful transaction with a `CallbackRejected(epoch, reason, oracleScore)` event, so refusals are visible on the explorer. Reason codes: 1 = latest score does not justify the action, 2 = latest verdict too old, 3 = callback epoch ahead of the oracle.

### The OpenAI exchange is auditable

Each published verdict in `ai/verdicts.jsonl` carries an `openai` object: the request exactly as sent (URL, model, temperature, strict-JSON mode, system prompt, the features JSON) and the model's raw response (content, usage, latency). The API key travels only in the Authorization header and is never logged (`trace shows request + response and never contains the API key`). The service also prints each exchange live (`SHOW_LLM=0` silences it).

## Output of the last run

```
=== Solidity safeguards (Foundry) ===
[PASS] test_noAiVerdict_noMovement() (gas: 159978)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 987.19µs (112.50µs CPU time)
[PASS] test_cooldownBlocksQuickFlipThenAllowsLater() (gas: 294586)
[PASS] test_hysteresis_middleBandDoesNotFlipBack() (gas: 298042)
[PASS] test_replayedEpochIgnored() (gas: 281567)
[PASS] test_staleVerdictIgnored() (gas: 69702)
[PASS] test_verdictExactlyMaxAgeStillValid() (gas: 272220)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 1.03ms (396.59µs CPU time)
[PASS] test_deRiskRejectsNonProxy() (gas: 13832)
[PASS] test_deRiskRejectsWrongReactiveSender() (gas: 11708)
[PASS] test_depositsPausedWhileRiskOff() (gas: 295330)
[PASS] test_duplicateAndStaleCallbacksAreIgnored() (gas: 253032)
[PASS] test_futureEpoch_isRejected() (gas: 122224)
[PASS] test_noVerdictEverPublished_rejects() (gas: 27916)
[PASS] test_reRiskRejectsNonProxyAndWrongSender() (gas: 16306)
[PASS] test_rejectedCallbackDoesNotConsumeEpoch() (gas: 245232)
[PASS] test_slippageGuardBlocksBadTrade() (gas: 295194)
[PASS] test_staleOracleVerdict_isRejected() (gas: 123617)
[PASS] test_supersededVerdict_cannotSellVault() (gas: 127672)
[PASS] test_userCanAlwaysWithdraw_evenIfReactiveNeverActs() (gas: 51596)
[PASS] test_verdictExactlyMaxAge_stillAccepted() (gas: 234172)
[PASS] test_wrongVerdict_calmOracleBlocksDeRisk() (gas: 135719)
[PASS] test_wrongVerdict_highOracleBlocksReRisk() (gas: 247437)
[PASS] test_wrongVerdict_middleBandBlocksBothDirections() (gas: 260880)
[PASS] test_wrongVerdict_thresholdsAreInclusive() (gas: 245564)
Suite result: ok. 17 passed; 0 failed; 0 skipped; finished in 1.64ms (1.01ms CPU time)
[PASS] test_onlySignerCanPublish() (gas: 13012)
[PASS] test_scoreAbove100Reverts() (gas: 13407)
[PASS] test_setSignerOnlyOwner() (gas: 101770)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 631.57µs (54.42µs CPU time)
Ran 4 test suites in 5.10ms (4.29ms CPU time): 26 tests passed, 0 failed, 0 skipped (26 total tests)

=== AI-service safeguards: API failure, wrong model verdict (node:test) ===
ok 1 - API down (HTTP 500 twice) => falls back to rule score and says so
ok 2 - bad API key (401) => fallback, no throw
ok 3 - network timeout (request never answers) => fallback within the timeout
ok 4 - model returns garbage / empty content => fallback
ok 5 - fallback in a calm market stays calm (no false alarm when the API is down)
ok 6 - model hallucinates a crash in a calm market => clamped below the de-risk threshold
ok 7 - model ignores an obvious crash => clamped above the de-risk threshold
ok 8 - model inside the band is respected (guard only fires when needed)
ok 9 - trace shows request + response and never contains the API key
ok 10 - quiet window with no swaps never calls the model
# pass 10
# fail 0
```

Full suites: `forge test` -> 63 passed; `cd ai && npm test` -> 33 passed.
