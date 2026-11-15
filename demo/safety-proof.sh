#!/usr/bin/env bash
# Runs exactly the tests that back the threat table in docs/SAFETY.md and prints PASS/FAIL per test.
# Usage: demo/safety-proof.sh            (needs forge on PATH; node 20+ for the AI half)
set -uo pipefail
cd "$(dirname "$0")/.."

SOL='test_wrongVerdict|test_supersededVerdict|test_staleOracleVerdict|test_verdictExactlyMaxAge|test_futureEpoch|test_noVerdictEverPublished|test_rejectedCallback|test_staleVerdictIgnored|test_verdictExactlyMaxAge|test_replayedEpochIgnored|test_duplicateAndStale|test_onlySignerCanPublish|test_setSignerOnlyOwner|test_scoreAbove100|test_deRiskRejects|test_reRiskRejects|test_slippageGuard|test_userCanAlwaysWithdraw|test_noAiVerdict|test_depositsPaused|test_hysteresis|test_cooldown'

echo "=== Solidity safeguards (Foundry) ==="
forge test ${FORGE_ARGS:-} --match-test "$SOL" 2>&1 | grep -E "^\[(PASS|FAIL)|tests passed|Suite result" 
echo
echo "=== AI-service safeguards: API failure, wrong model verdict (node:test) ==="
(cd ai && node --test test/safety.test.js 2>&1 | grep -E "^(ok|not ok)|^# (pass|fail)")
