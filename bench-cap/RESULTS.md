# Latency benchmark (Base Sepolia + Reactive Lasna)

10 samples from 5 complete demo cycles (5 de-risk, 5 re-risk). Each cycle is `demo/run-demo.sh`: a staged crash, the AI verdict, the Lasna reaction and the vault de-risk, then a recovery swap and the re-risk.

## How it is measured

- All times are on-chain block timestamps (1 s resolution, so each number is +/-1 s), computed by `demo/proof.sh`. No wall-clock of the measuring machine is involved, and every sample below links its transactions.
- The *trigger swap* is the last pool swap before the AI verdict, as in `demo/proof.sh`. The swap-to-verdict step includes the AI service's polling cadence (defaults in `ai/src/config.js`: poll 3 s, evaluate at least every 15 s), feature computation, the OpenAI call and transaction confirmation, so it is dominated by the AI, not by Reactive Network.
- *Verdict on-chain -> vault moved* is the part Reactive Network owns: oracle event, Lasna reaction, callback delivery.
- The Lasna block timestamps are not used: they have the same 1 s resolution but come from a different chain clock, so splitting the Reactive part further would not be meaningful.
- With n = 10, p95 is essentially the maximum. These are testnet numbers on public RPCs, not a performance claim.

## All samples

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 10 | 5 | 9 | 12 | 12 | 8.9 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 10 | 1 | 1.5 | 2 | 2 | 1.5 |
| Trigger swap -> vault moved (end to end) | 10 | 6 | 10.5 | 14 | 14 | 10.4 |

## De-risk (crash)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 5 | 5 | 9 | 11 | 11 | 8 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 5 | 1 | 1 | 2 | 2 | 1.4 |
| Trigger swap -> vault moved (end to end) | 5 | 6 | 10 | 13 | 13 | 9.4 |

## Re-risk (recovery)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 5 | 7 | 10 | 12 | 12 | 9.8 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 5 | 1 | 2 | 2 | 2 | 1.6 |
| Trigger swap -> vault moved (end to end) | 5 | 9 | 11 | 14 | 14 | 11.4 |

## What a cycle costs the reactive contract

Reserves at the Lasna system contract, read before each cycle: 4 consecutive pair(s) without a top-up, average drop 0.0552 REACT per cycle (min 0.0552, max 0.0552). One cycle is a de-risk and a re-risk plus the idle verdicts the AI service publishes in between, so this is an upper estimate for one reaction pair.

## Every sample

| Run | Epoch | Dir | Score | Swap->verdict s | Verdict->vault s | Swap->vault s | Verdict tx | Vault callback tx |
|---|---|---|---|---|---|---|---|---|
| run-001 | 235 | de-risk | 70 | 9 | 2 | 11 | [0x737f6b75](https://sepolia.basescan.org/tx/0x737f6b757a256cb0015646cebf0387d91b6a0eb86a1bf21334a68e68efaeaee8) | [0x65c83d40](https://sepolia.basescan.org/tx/0x65c83d40748b9c5da47ea60a983face4720f67988a124e44bfe21036b63a7f94) |
| run-001 | 237 | re-risk | 30 | 11 | 2 | 13 | [0x3a742c9e](https://sepolia.basescan.org/tx/0x3a742c9e9826ef7abaede70fd03ea6a930b1f37331c04a377175af7645bf9400) | [0xbd8027d6](https://sepolia.basescan.org/tx/0xbd8027d6fd3ae1c6fb2dbb44e513f243c392d31886563be8b428da7595a78271) |
| run-002 | 240 | de-risk | 100 | 5 | 1 | 6 | [0x060e8235](https://sepolia.basescan.org/tx/0x060e8235d48ace3d55d515359d0b7e790b157eb50f3e085c98dc9caa308f7238) | [0xe6b5b434](https://sepolia.basescan.org/tx/0xe6b5b434cc226c73578eb4a8ff18d1046d5008de91fc90a68424024b39478211) |
| run-002 | 241 | re-risk | 30 | 7 | 2 | 9 | [0x9d63470b](https://sepolia.basescan.org/tx/0x9d63470be3c620fae184ba035a5fa4f1cd18707fabee34fff807b9b39d5004fe) | [0xe7baeae3](https://sepolia.basescan.org/tx/0xe7baeae3bebb95477f5265d9bb1b25535892781cc8403b1b95d621226f0e2a0b) |
| run-003 | 243 | de-risk | 70 | 6 | 1 | 7 | [0x46bab7eb](https://sepolia.basescan.org/tx/0x46bab7ebe75f2205e86e40ee54e9f8f754455ad085f9880bb7666e86872708af) | [0x28ee2779](https://sepolia.basescan.org/tx/0x28ee2779ad3f00e1b21599d177901b486c2bc736b16db8b47aafd9095df7199c) |
| run-003 | 245 | re-risk | 30 | 9 | 1 | 10 | [0xec0aaf39](https://sepolia.basescan.org/tx/0xec0aaf39abd130582bdeb5d4db9c1c38ac679ccf3a53956479671c60cd0c47e0) | [0x18018d4d](https://sepolia.basescan.org/tx/0x18018d4d5d14a8d28b4594009e35cc97d52db8d5256439948cd57d2e2f83f43e) |
| run-004 | 247 | de-risk | 70 | 9 | 1 | 10 | [0xbbb07d14](https://sepolia.basescan.org/tx/0xbbb07d14559ddd71652c8c459a3592ecb1fabea65b8109dd8aded2b2ed817ecf) | [0xbf0d9776](https://sepolia.basescan.org/tx/0xbf0d9776a3d2dcebcbb0f2d40a04f27ae24c2564fbaeb7bfd8c7f49af6ee0d37) |
| run-004 | 249 | re-risk | 30 | 10 | 1 | 11 | [0x186626ca](https://sepolia.basescan.org/tx/0x186626cab5d21ead2adacf3461610d7323b6b3ffe3425eb8fb239c6f65db5835) | [0xc8474347](https://sepolia.basescan.org/tx/0xc8474347f04c4b15e785c5727080256dec16579984069e6b4410ce1b96f89e08) |
| run-005 | 251 | de-risk | 70 | 11 | 2 | 13 | [0xe6d7ab52](https://sepolia.basescan.org/tx/0xe6d7ab523161b0bac0383b46230b79b0cbc4f20fa6ae8770170b0d07e081eaa8) | [0xc286e873](https://sepolia.basescan.org/tx/0xc286e8738fc3802cc900d80c730b3b639e8077b5355141f16f1435fe1d009f5d) |
| run-005 | 253 | re-risk | 30 | 12 | 2 | 14 | [0xca9d0fdb](https://sepolia.basescan.org/tx/0xca9d0fdbeb9f377bde300199c939b055ae9cce622caee9ef8ae6fe679225cbe3) | [0xd4c1c4ab](https://sepolia.basescan.org/tx/0xd4c1c4ab8162be56e1f34fd64aa97f9e4e690c9c1150763e95483dae04160c5a) |
