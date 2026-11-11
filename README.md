# Guardian Vault (Reactive Omni Buildathon — Reactive Meets AI)

Status: **Week 1** "hello reactive" loop deployed and verified on Lasna + Base Sepolia (see `NOTES.md`). **Week 2** (this section below) adds the Guardian Vault: mock pool, risk oracle, vault, reactive decision contract.

```
Base Sepolia                     Reactive Lasna                     Base Sepolia
HelloOrigin.ping(v)  ──event──►  HelloReactive.react()  ──callback─► HelloCallback.onPong()
 (emits Ping)                    (requestCallbackV_1_0)              (via callback proxy)
```

Final target (weeks 2-4): mock pool + risk oracle (AI-signed) + vault, same pattern.

## Layout

| File | Chain | Role |
|---|---|---|
| `src/HelloOrigin.sol` | Base Sepolia | emits `Ping(sender, id, value)` |
| `src/HelloReactive.sol` | Reactive Lasna | subscribes to `Ping`, requests callback |
| `src/HelloCallback.sol` | Base Sepolia | receives callback; guarded by `onlyServiceProvider` + `onlyCallbackSender` |
| `test/HelloLoop.t.sol` | local | 10 tests (mock system contract at `0x8888…8888`) |
| `script/Deploy.s.sol` | — | deploy + link + ping scripts |

Built on `reactive-lib-omni` (Omni fork: **no RVM, single deployment**, solc 0.8.29, system contract `0x8888…8888`).

## Setup (WSL / Linux)

```bash
cd guardian-vault
forge install            # pulls lib/forge-std and lib/reactive-lib-omni (submodules)
forge build
forge test               # expect: 10 passed
cp .env.example .env     # then edit, then:  source .env
```

If `forge build` can't download solc (blocked network), download `solc-static-linux` v0.8.29 from
github.com/ethereum/solidity/releases, `chmod +x` it, and run `forge build --use ./solc-static-linux --offline`.

## Deploy to testnets

Wallet needs: **Base Sepolia ETH** (deploy + fund callback) and **lREACT** on Lasna (you have this).
Use a throwaway testnet wallet imported with `cast wallet import testdeployer --interactive`.

```bash
source .env

# 1. Origin (Base Sepolia)  -> copy printed address into ORIGIN_ADDRESS
forge script script/Deploy.s.sol:DeployOrigin --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast

# 2. Reactive (Lasna)       -> copy printed address into REACTIVE_ADDRESS
source .env
forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast

# 3. Callback (Base Sepolia) -> copy printed address into CALLBACK_ADDRESS
source .env
forge script script/Deploy.s.sol:DeployCallback --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast

# 4. Link (Lasna): reactive learns where to send callbacks (one-time)
source .env
forge script script/Deploy.s.sol:LinkRecipient --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast

# 5. Fire the loop (Base Sepolia)
forge script script/Deploy.s.sol:PingOrigin --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
```

Windows PowerShell users: run these inside WSL (they use `source`).

### Verify the loop worked

```bash
cast call $CALLBACK_ADDRESS "pongCount()(uint256)" --rpc-url $BASE_SEPOLIA_RPC
cast call $CALLBACK_ADDRESS "lastValue()(uint256)"  --rpc-url $BASE_SEPOLIA_RPC   # 42
cast call $REACTIVE_ADDRESS "reactCount()(uint256)" --rpc-url $LASNA_RPC
```

Wait ~5-20 seconds after step 5. Save these for the submission: the `ping` tx hash (Base), the reactive
tx on Lasna (https://lasna.reactscan.net → your reactive contract), and the callback tx hash (Base).
That origin → reactive → callback chain is exactly what the judges score under **Execution**.

## Troubleshooting

- **Nothing arrives**: callback contract must hold ETH (billed there, not on Lasna), and the reactive
  contract must hold lREACT. Top up with a plain transfer.
- **`forge script` on Lasna fails with gas/fee errors**: retry with `--legacy`, or add `--gas-price`.
- **Callback reverts `NotAuthorized` / `CallbackNotAuthorized`**: wrong proxy address or
  `REACTIVE_ADDRESS` mismatch. `callbackSender` is immutable; redeploy the callback if wrong.
- **MetaMask "Smart Transaction interrupted"** when sending to faucets: disable Smart Transactions.
- Base Sepolia blocks are 200 ms: use `block.timestamp`, never block counts, for timers/cooldowns.

## Buildathon rules checklist

- [ ] Repo public and open-source at submission
- [ ] Everything built during the event (Nov 5 – Dec 5); only dependencies may pre-exist
- [ ] Submission: repo link, deployed addresses, tx hashes for the full loop, demo video < 3 min
- [ ] AI model must be part of the **running** system (week 3)


---

# Week 2: Guardian Vault

An AI watches a pool, publishes a risk verdict on-chain, and a Reactive contract (not a bot, not the AI)
decides whether the vault moves its funds to the safe asset. Users can always withdraw.

```
 Base Sepolia                                 Reactive Lasna                       Base Sepolia
 MockPool.Swap events ──► AI service ──publishRisk──► RiskOracle ──RiskUpdated──► GuardianReactive ──callback──► GuardianVault.deRisk()/reRisk()
 (price moves)            (off-chain, week 3)         (AI signer only)             (thresholds, cooldown,                (proxy + reactive-only,
                                                                                    staleness, replay guard)              slippage-guarded swap)
```

| Contract | Chain | Role |
|---|---|---|
| `MockToken` | Base | gVOL (volatile) and gUSD (stable) test tokens, open `mint` |
| `MockPool` | Base | x*y=k pool; every `Swap` emits the post-swap price so the AI can read it; lets the demo crash the price on demand |
| `RiskOracle` | Base | `publishRisk(score, reasonHash)`, **AI signer wallet only**; emits `RiskUpdated(epoch, score, timestamp, reasonHash)` |
| `GuardianReactive` | Lasna | subscribes to `RiskUpdated`; decides; requests the callback |
| `GuardianVault` | Base | holds gVOL; `deRisk`/`reRisk` callable only by the callback proxy **and** only for our reactive contract |

## What the Reactive contract decides (this is the "integration" the judges look at)

- **Hysteresis:** de-risk at score >= `HIGH` (70), re-risk only at score <= `LOW` (30). Scores in between do nothing, so a score wobbling near one line cannot flip-flop the vault.
- **Cooldown:** no second action within `COOLDOWN` (60 s) of the last, measured with `block.timestamp` (Base blocks are ~200 ms, never count blocks).
- **Staleness:** a verdict older than `MAX_AGE` (600 s) is ignored.
- **Replay protection:** only epochs newer than the last one seen count.

Without a fresh AI verdict nothing downstream moves, so the model is a required part of the loop.

## Safety properties (each one has a test)

1. `withdraw()` always works, whatever the AI, oracle or Reactive Network do.
2. `deRisk`/`reRisk` revert for anyone except callback proxy + our reactive contract.
3. Swaps are slippage-guarded against pool spot price (default 10%, owner can raise to at most 50%); a failed guard reverts and leaves state untouched.
4. Stale/duplicate callbacks are ignored (`CallbackIgnored` event), not executed.
5. Deposits are paused while risk-off.
6. Only the AI signer can publish risk; the owner can rotate the signer.

## Deploy (WSL, from `guardian-vault/`)

Add the new variables to your existing `.env` (copy the "Week 2" block from `.env.example`), then run each step,
paste the printed address into `.env`, and `source .env` again.

```bash
source .env
# 1 Base: tokens + pool + oracle          -> VOL_ADDRESS STABLE_ADDRESS POOL_ADDRESS ORACLE_ADDRESS
forge script script/Guardian.s.sol:DeployMarket --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
# 2 Lasna: reactive contract (1 lREACT)   -> G_REACTIVE_ADDRESS
forge script script/Guardian.s.sol:DeployGuardianReactive --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
# 3 Base: vault (0.01 ETH for callbacks)  -> VAULT_ADDRESS
forge script script/Guardian.s.sol:DeployVault --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
# 4 Lasna: link reactive -> vault (once)
forge script script/Guardian.s.sol:LinkVault --rpc-url $LASNA_RPC --account $ACCOUNT --broadcast
# 5 Base: deposit 100 gVOL into the vault
forge script script/Guardian.s.sol:SeedVault --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
```

## Demo script (until the AI service exists in week 3 you play the AI with `PublishRisk`)

```bash
# crash the pool price (5000 gVOL dumped into a 10k/10k pool: price ~1.0 -> ~0.44)
forge script script/Guardian.s.sol:CrashPool --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
# the "AI" says danger
RISK_SCORE=92 RISK_REASON="price -55% in one swap" \
forge script script/Guardian.s.sol:PublishRisk --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
# ~seconds later: vault should be risk-off, holding gUSD
cast call $VAULT_ADDRESS "riskOff()(bool)" --rpc-url $BASE_SEPOLIA_RPC
cast call $VAULT_ADDRESS "holdings()(uint256,uint256)" --rpc-url $BASE_SEPOLIA_RPC

# recovery (wait > 60 s for the cooldown first)
forge script script/Guardian.s.sol:RecoverPool --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
RISK_SCORE=15 RISK_REASON="volatility normalised" \
forge script script/Guardian.s.sol:PublishRisk --rpc-url $BASE_SEPOLIA_RPC --account $ACCOUNT --broadcast
cast call $VAULT_ADDRESS "riskOff()(bool)" --rpc-url $BASE_SEPOLIA_RPC   # false again
```

Collect evidence the same way as week 1: the `PublishRisk` tx hash (Base), the reactive tx on Lasna
(`cast logs --address $G_REACTIVE_ADDRESS "ActionRequested(uint256 indexed,uint8,bool)" --from-block <lasna block> --rpc-url $LASNA_RPC`),
and the vault callback tx on Base (`cast logs --address $VAULT_ADDRESS "DeRisked(uint256 indexed,uint256,uint256,uint256)" --from-block <N> --to-block <N+200> --rpc-url $BASE_SEPOLIA_RPC`; public Base RPC limits `eth_getLogs` to 200 blocks).

## Honest notes for the write-up

- In this demo the AI reacts to a crash that already happened, so the vault sells into the crashed pool: it limits *further* loss, it does not avoid the first drop. Say so in the submission; what is being proven is the automated AI -> Reactive -> vault loop and its safety properties.
- The pool and tokens are mocks so the scenario is reproducible on testnet.
- Latency numbers must include the AI inference time, not just chain hops.
