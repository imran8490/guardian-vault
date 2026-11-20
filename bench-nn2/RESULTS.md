# Latency benchmark (Base Sepolia + Reactive Lasna)

9 samples from 5 complete demo cycles (4 de-risk, 5 re-risk). Each cycle is `demo/run-demo.sh`: a staged crash, the AI verdict, the Lasna reaction and the vault de-risk, then a recovery swap and the re-risk.

## How it is measured

- All times are on-chain block timestamps (1 s resolution, so each number is +/-1 s), computed by `demo/proof.sh`. No wall-clock of the measuring machine is involved, and every sample below links its transactions.
- The *trigger swap* is the last pool swap before the AI verdict, as in `demo/proof.sh`. The swap-to-verdict step includes the AI service's polling cadence (defaults in `ai/src/config.js`: poll 3 s, evaluate at least every 15 s), feature computation, the OpenAI call and transaction confirmation, so it is dominated by the AI, not by Reactive Network.
- *Verdict on-chain -> vault moved* is the part Reactive Network owns: oracle event, Lasna reaction, callback delivery.
- The Lasna block timestamps are not used: they have the same 1 s resolution but come from a different chain clock, so splitting the Reactive part further would not be meaningful.
- With n = 9, p95 is essentially the maximum. These are testnet numbers on public RPCs, not a performance claim.

## All samples

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 9 | 5 | 9 | 12 | 12 | 8.9 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 9 | 1 | 2 | 2 | 2 | 1.6 |
| Trigger swap -> vault moved (end to end) | 9 | 6 | 11 | 14 | 14 | 10.4 |

## De-risk (crash)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 4 | 5 | 8.5 | 10 | 10 | 8 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 4 | 1 | 1 | 2 | 2 | 1.2 |
| Trigger swap -> vault moved (end to end) | 4 | 6 | 9.5 | 12 | 12 | 9.2 |

## Re-risk (recovery)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 5 | 8 | 9 | 12 | 12 | 9.6 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 5 | 1 | 2 | 2 | 2 | 1.8 |
| Trigger swap -> vault moved (end to end) | 5 | 9 | 11 | 14 | 14 | 11.4 |

## What a cycle costs the reactive contract

Reserves at the Lasna system contract, read before each cycle: 3 consecutive pair(s) without a top-up, average drop 0.0802 REACT per cycle (min 0.0552, max 0.1052). One cycle is a de-risk and a re-risk plus the idle verdicts the AI service publishes in between, so this is an upper estimate for one reaction pair.

## Every sample

| Run | Epoch | Dir | Score | Swap->verdict s | Verdict->vault s | Swap->vault s | Verdict tx | Vault callback tx |
|---|---|---|---|---|---|---|---|---|
| run-001 | 203 | de-risk | 81 | 7 | 1 | 8 | [0x2f6d43ba](https://sepolia.basescan.org/tx/0x2f6d43ba206ffef8748564748ee35fd4fe86bb2b06b873809a2883ea3bc97305) | [0xd85f4cc1](https://sepolia.basescan.org/tx/0xd85f4cc13f2fce3da98a45a5a64c69b786cb3f388650348c5c72f469073b481e) |
| run-001 | 205 | re-risk | 30 | 8 | 2 | 10 | [0xe0653c26](https://sepolia.basescan.org/tx/0xe0653c267837f80e61336096d8f39b60a14d03af6eeb295bc843ceec94cec99c) | [0x7bd4d6a4](https://sepolia.basescan.org/tx/0x7bd4d6a4c7bf613d4c2b6f90761628194fb9e7bc1b0ebb23e30c3f03a47fb8a6) |
| run-002 | 211 | re-risk | 30 | 8 | 1 | 9 | [0x64ca1c38](https://sepolia.basescan.org/tx/0x64ca1c38653ecd04f68ac7d3a0666d0c659a7122daccca6021eabd9a68b0c8df) | [0xce03e9ea](https://sepolia.basescan.org/tx/0xce03e9ea701af224858b4ba4f7bdbae490532d5531c4b0194b66d93aab1c0de7) |
| run-003 | 217 | de-risk | 80 | 10 | 2 | 12 | [0xb262f1b6](https://sepolia.basescan.org/tx/0xb262f1b643efb1ceb87370b45d6c9a11cb32d0d2e735a4ea5e3f587b021ff550) | [0xfcea1129](https://sepolia.basescan.org/tx/0xfcea11298133b8a72309912eb9c7de736a9913d265b2f71792da68a204bd81a3) |
| run-003 | 219 | re-risk | 30 | 9 | 2 | 11 | [0x0538e90f](https://sepolia.basescan.org/tx/0x0538e90fb9c5e34a46d61a734f6d7160f6ccc2b49126118ce432f39f33243e9b) | [0x8af36dfd](https://sepolia.basescan.org/tx/0x8af36dfdd19eac1f0887cdc31267afdc434cf811b59346c96093ed19ec449a7c) |
| run-004 | 223 | de-risk | 82 | 5 | 1 | 6 | [0xaa5c7bdd](https://sepolia.basescan.org/tx/0xaa5c7bdd3c004a92a70fd616bec4970d9b18b9a9320b64cf695a8c703710e695) | [0xc2baa6cd](https://sepolia.basescan.org/tx/0xc2baa6cdd788307c86f0b54edb5e7183fce68289eb5fc4075e2932c30395ecf6) |
| run-004 | 225 | re-risk | 30 | 12 | 2 | 14 | [0x63a14832](https://sepolia.basescan.org/tx/0x63a14832fc88df99e5aebc268a95eca5b9b6e01307edf37513559489b43b8f1f) | [0xdcae9319](https://sepolia.basescan.org/tx/0xdcae9319e996a4458dec111f56f517857ea5ecb3e2c3f5135fb56d83c28f6ad1) |
| run-005 | 228 | de-risk | 72 | 10 | 1 | 11 | [0xf5a3e9bc](https://sepolia.basescan.org/tx/0xf5a3e9bcfa18776bc5dd2a86ed6d2ba0b50e456cc6aa37a29cb7e7612b07fa25) | [0x1753be44](https://sepolia.basescan.org/tx/0x1753be44f5076098a3f003e4da548d1333379c971759f572ab89da6a6e20eb3a) |
| run-005 | 230 | re-risk | 30 | 11 | 2 | 13 | [0x97b16896](https://sepolia.basescan.org/tx/0x97b16896b557362e7a7e040a762eeb3bd522f282f6afd8afefbacfba69d94de5) | [0xd3cff924](https://sepolia.basescan.org/tx/0xd3cff924a9d758346bf55ad7c90351120b6dc9e82c15298cb83e7ece6c1b6305) |

## Samples that could not be parsed (excluded)

- run-002.log epoch 209: no vault callback or publish line found
