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
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 10 | 10 | 13 | 64 | 64 | 28.9 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 10 | 0 | 1 | 2 | 2 | 1 |
| Trigger swap -> vault moved (end to end) | 10 | 11 | 13 | 66 | 66 | 29.9 |

## De-risk (crash)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 5 | 10 | 10 | 13 | 13 | 10.6 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 5 | 0 | 1 | 2 | 2 | 1 |
| Trigger swap -> vault moved (end to end) | 5 | 11 | 11 | 13 | 13 | 11.6 |

## Re-risk (recovery)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 5 | 13 | 59 | 64 | 64 | 47.2 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 5 | 0 | 1 | 2 | 2 | 1 |
| Trigger swap -> vault moved (end to end) | 5 | 13 | 60 | 66 | 66 | 48.2 |

## What a cycle costs the reactive contract

Reserves at the Lasna system contract, read before each cycle: 3 consecutive pair(s) without a top-up, average drop 0.1615 REACT per cycle (min 0.1443, max 0.1700). One cycle is a de-risk and a re-risk plus the idle verdicts the AI service publishes in between, so this is an upper estimate for one reaction pair.

## Every sample

| Run | Epoch | Dir | Score | Swap->verdict s | Verdict->vault s | Swap->vault s | Verdict tx | Vault callback tx |
|---|---|---|---|---|---|---|---|---|
| run-001 | 16 | de-risk | 70 | 10 | 1 | 11 | [0x20814435](https://sepolia.basescan.org/tx/0x208144350a0038032e1d4c6ce4cd44339f51cc9e199c3b2b191b111ede393050) | [0x9fd27728](https://sepolia.basescan.org/tx/0x9fd277283ea8dbf827eade96fc13de1b38154e085fa98a2b4f19ef861acc80bf) |
| run-001 | 18 | re-risk | 30 | 13 | 0 | 13 | [0x83d1a8ec](https://sepolia.basescan.org/tx/0x83d1a8eceaecf9bedd3a24b85bb29e67a798b67241506b39fc09830bd47079c7) | [0x7d0b058a](https://sepolia.basescan.org/tx/0x7d0b058a6da02d00764b0f3324ad2e90a9e83bd6682cddad6bac27fd1122b3e3) |
| run-002 | 20 | de-risk | 70 | 10 | 1 | 11 | [0x9d5a791a](https://sepolia.basescan.org/tx/0x9d5a791a053cfa55c2bceb9028775a74cde60f55e8e332ea127f032071d1cfdb) | [0x971fe6a3](https://sepolia.basescan.org/tx/0x971fe6a34c572a78f1b2cbc3f9b7b4f61d55af68c74e889c7a7596b72db8a7c8) |
| run-002 | 23 | re-risk | 30 | 59 | 1 | 60 | [0x641fa873](https://sepolia.basescan.org/tx/0x641fa873bc5388aaac730bae0346c2ee072c1da2626cc430e465e8d1758c0908) | [0xce26acd8](https://sepolia.basescan.org/tx/0xce26acd8eeafdd9c0972ed748482a0413e55c1489eb35c66e8b4b253ffe35acc) |
| run-003 | 26 | de-risk | 70 | 10 | 1 | 11 | [0xf2a8ccb8](https://sepolia.basescan.org/tx/0xf2a8ccb809b4bb782250587f52e9e69575fc09546860892560c324fb327b1bff) | [0xd66450b7](https://sepolia.basescan.org/tx/0xd66450b78e54e95071700a926a089ed203091fa1b652674e7a324858268f4314) |
| run-003 | 29 | re-risk | 30 | 64 | 2 | 66 | [0x43d5f3e9](https://sepolia.basescan.org/tx/0x43d5f3e9732ba89ef929da36feaf2e49f33ec05347b55fba237a5a7d1efd8a1b) | [0xf82040c7](https://sepolia.basescan.org/tx/0xf82040c773bf09e018ab2647db25133e336c9ac88ed8fecda10c598bf8abd712) |
| run-004 | 32 | de-risk | 70 | 10 | 2 | 12 | [0x59bd3325](https://sepolia.basescan.org/tx/0x59bd33253e2a2a8f0f6df0a8a291455726d2a544a19c1ac135040faa34a5ac65) | [0x9aa08351](https://sepolia.basescan.org/tx/0x9aa083519563cc1313a8c01d430866fe5178987bb62ce87c923f47c5ad069e33) |
| run-004 | 35 | re-risk | 30 | 59 | 1 | 60 | [0xb560f453](https://sepolia.basescan.org/tx/0xb560f453192a5c602b13f658d6d21f288f1f534adbb8cc07a6733f8af8ac255e) | [0xe5d3a4a2](https://sepolia.basescan.org/tx/0xe5d3a4a2fa9e09e35722f2688d472c768d57ff71396087a3a81a008ab27ca42e) |
| run-005 | 37 | de-risk | 70 | 13 | 0 | 13 | [0xc59a7dc4](https://sepolia.basescan.org/tx/0xc59a7dc4e14eba628a4900baefc7743299e5872c413001d5dcc5ccd40a5f9f1d) | [0x5e01f0e9](https://sepolia.basescan.org/tx/0x5e01f0e97dd2e97bf39e4943e06d4b40749688876ee1a3dca0afc68923257d3c) |
| run-005 | 40 | re-risk | 30 | 41 | 1 | 42 | [0x9acdd9b1](https://sepolia.basescan.org/tx/0x9acdd9b16eb2ebf61ba31be40d3eff408ddfb556dad5d75836796a1e0a5920dd) | [0xa440f8f1](https://sepolia.basescan.org/tx/0xa440f8f1e514f05ec720f9d91f80024e55eb9638a634dd402b6ed978392a8b8a) |
