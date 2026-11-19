# Latency benchmark (Base Sepolia + Reactive Lasna)

20 samples from 10 complete demo cycles (10 de-risk, 10 re-risk); 1 further run(s) failed and produced no samples (see the run logs). Each cycle is `demo/run-demo.sh`: a staged crash, the AI verdict, the Lasna reaction and the vault de-risk, then a recovery swap and the re-risk.

## How it is measured

- All times are on-chain block timestamps (1 s resolution, so each number is +/-1 s), computed by `demo/proof.sh`. No wall-clock of the measuring machine is involved, and every sample below links its transactions.
- The *trigger swap* is the last pool swap before the AI verdict, as in `demo/proof.sh`. The swap-to-verdict step includes the AI service's polling cadence (defaults in `ai/src/config.js`: poll 3 s, evaluate at least every 15 s), feature computation, the OpenAI call and transaction confirmation, so it is dominated by the AI, not by Reactive Network.
- *Verdict on-chain -> vault moved* is the part Reactive Network owns: oracle event, Lasna reaction, callback delivery.
- The Lasna block timestamps are not used: they have the same 1 s resolution but come from a different chain clock, so splitting the Reactive part further would not be meaningful.
- With n = 20, p95 is essentially the maximum. These are testnet numbers on public RPCs, not a performance claim.

## All samples

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 20 | 5 | 10.5 | 75 | 83 | 26.4 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 20 | 1 | 1 | 2 | 2 | 1.4 |
| Trigger swap -> vault moved (end to end) | 20 | 6 | 12 | 77 | 84 | 27.7 |

## De-risk (crash)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 10 | 5 | 7.5 | 75 | 75 | 15.3 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 10 | 1 | 1 | 2 | 2 | 1.3 |
| Trigger swap -> vault moved (end to end) | 10 | 6 | 9 | 77 | 77 | 16.6 |

## Re-risk (recovery)

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 10 | 7 | 42 | 83 | 83 | 37.4 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 10 | 1 | 1 | 2 | 2 | 1.4 |
| Trigger swap -> vault moved (end to end) | 10 | 8 | 43.5 | 84 | 84 | 38.8 |

## Only samples with an OpenAI call

| Step | n | min s | median s | p95 s | max s | mean s |
|---|---|---|---|---|---|---|
| Trigger swap -> AI verdict on-chain (poll + features + LLM + tx) | 19 | 5 | 9 | 83 | 83 | 24.7 |
| Verdict on-chain -> vault moved (oracle event -> Lasna -> callback) | 19 | 1 | 1 | 2 | 2 | 1.3 |
| Trigger swap -> vault moved (end to end) | 19 | 6 | 10 | 84 | 84 | 26 |

1 sample(s) had no LLM call (calm, no-swap verdict), so they are left out of this table.

## What a cycle costs the reactive contract

Reserves at the Lasna system contract, read before each cycle: 7 consecutive pair(s) without a top-up, average drop 0.0695 REACT per cycle (min 0.0677, max 0.0802). One cycle is a de-risk and a re-risk plus the idle verdicts the AI service publishes in between, so this is an upper estimate for one reaction pair.

## Every sample

| Run | Epoch | Dir | Score | Swap->verdict s | Verdict->vault s | Swap->vault s | Verdict tx | Vault callback tx |
|---|---|---|---|---|---|---|---|---|
| run-001 | 103 | de-risk | 70 | 19 | 1 | 20 | [0x1f6c1e7a](https://sepolia.basescan.org/tx/0x1f6c1e7aa4841d2827046ae29168f073818f79484c67d98a256d63c5235fdcff) | [0x06a0ad93](https://sepolia.basescan.org/tx/0x06a0ad9353c6afd5b19d7218261dd9b9f52d86dbabd1efbc882ee7742e44b398) |
| run-001 | 105 | re-risk | 30 | 9 | 1 | 10 | [0xdf16090d](https://sepolia.basescan.org/tx/0xdf16090d16accd83474ec6877663653ccacf5f1dbe956f9becada085bcab9691) | [0x0bd49fcc](https://sepolia.basescan.org/tx/0x0bd49fcc18bf5a18c29f85b70d91e22170b0b7ab7771265fdcc7e3f9aad3fdb4) |
| run-002 | 107 | de-risk | 70 | 15 | 1 | 16 | [0xe965b8f6](https://sepolia.basescan.org/tx/0xe965b8f6224e40b200661167ccddfcce84a0ed38bdbc828bb5c964e8092a0c59) | [0xaf2baf49](https://sepolia.basescan.org/tx/0xaf2baf4945cc54757da3465bb6fb352cce6aff91ab7029c16f420866ba42d0b6) |
| run-002 | 109 | re-risk | 30 | 7 | 1 | 8 | [0x134269a7](https://sepolia.basescan.org/tx/0x134269a763dfb75d43981ef14cfd54a1a332bed7ce6da5cb04de2e312fddda7a) | [0x75a85f1a](https://sepolia.basescan.org/tx/0x75a85f1a35c5c220c42fbf3ed133c5adeabb60fd49da41c1871f4e89e94be602) |
| run-004 | 149 | de-risk | 70 | 75 | 2 | 77 | [0xe2d2a9e5](https://sepolia.basescan.org/tx/0xe2d2a9e57453669caedd2e91bbbb1b080cd30d062096f3f507ea9fd8c98645c3) | [0x3f4d127c](https://sepolia.basescan.org/tx/0x3f4d127ca825da1c44948f89ae8be157261c30709a9577f24402cbf0d60a2bb7) |
| run-004 | 151 | re-risk | 30 | 12 | 2 | 14 | [0xade9cd1f](https://sepolia.basescan.org/tx/0xade9cd1f9845e07aaee79c2ade8a1b9b80156fec6319b94fb842cced944dad85) | [0xc34e633c](https://sepolia.basescan.org/tx/0xc34e633c7a8f212967d129df81ee454a7485026b2c829a91f05db6d8f1aba103) |
| run-005 | 155 | de-risk | 70 | 5 | 2 | 7 | [0xd540ced8](https://sepolia.basescan.org/tx/0xd540ced8f3f0789584e690ee8163b5f9448cd00bb38e89c7e848ecf2289c8633) | [0xef32a58c](https://sepolia.basescan.org/tx/0xef32a58c40b1f8711eb93ebe34deabdc6d7d9fa303b4dc87efc90b65a6af710e) |
| run-005 | 157 | re-risk | 30 | 8 | 1 | 9 | [0xf50751cb](https://sepolia.basescan.org/tx/0xf50751cb8c7d68df7d800949be7c51a3f6252ab35fe581a0ef6e3c2cd379d244) | [0x98fbf32e](https://sepolia.basescan.org/tx/0x98fbf32e1f2070ba4699fe2621bef14619b1cd0b82fcef5d29c8b3725c460e25) |
| run-006 | 159 | de-risk | 70 | 7 | 2 | 9 | [0xfacec6c7](https://sepolia.basescan.org/tx/0xfacec6c7ae0f87aa6d2e9235d20410f5c44a404fa07edf2d4438aabb6124280b) | [0xf0c8ebcc](https://sepolia.basescan.org/tx/0xf0c8ebccd2fb7e6264135774970e00fe81a80490b57426ee28bfcdcf12aa7daa) |
| run-006 | 162 | re-risk | 30 | 43 | 2 | 45 | [0x1d677915](https://sepolia.basescan.org/tx/0x1d677915935305daa8b8825e9ff9f4e4280969c86ed99ff0064a9ac8b5102d02) | [0x8bf26dad](https://sepolia.basescan.org/tx/0x8bf26dad6a59baa5fa2b187e1ad8f3f05b75eb77e8c73d7539c8ca02b5183c87) |
| run-007 | 164 | de-risk | 70 | 8 | 1 | 9 | [0x0d496355](https://sepolia.basescan.org/tx/0x0d496355a1f350d32b86c555e32b214ffd8d5b968d4062752351b509ce25211b) | [0xba55082f](https://sepolia.basescan.org/tx/0xba55082f8353c6b81936bc246deb8d22186c3f300bb7003207987c0054761ee6) |
| run-007 | 167 | re-risk | 30 | 41 | 1 | 42 | [0xa841795e](https://sepolia.basescan.org/tx/0xa841795eb8f1a31c8269b5f5884dea9f3be5795bb3863227db6c08cf3786e677) | [0x0a8e375d](https://sepolia.basescan.org/tx/0x0a8e375d9d7f310d028d7e54cfa67ce464ae6629900781a3e4907aa11de8a835) |
| run-008 | 169 | de-risk | 70 | 8 | 1 | 9 | [0x842d449b](https://sepolia.basescan.org/tx/0x842d449b61b0df6b4d5052dd5e10006c15d4d876725744becdaa17e79e4d0776) | [0x9f7033ff](https://sepolia.basescan.org/tx/0x9f7033ffe0059a331afa4b4163364a3c3d794951a53b3aa02a60511708e9fbe0) |
| run-008 | 172 | re-risk | 30 | 54 | 1 | 55 | [0x7a2ab34d](https://sepolia.basescan.org/tx/0x7a2ab34d44fcb41e9ec777a13dfedd1f0977e5a70e986e73564304090ee9f49a) | [0x0521e1dc](https://sepolia.basescan.org/tx/0x0521e1dcbbf28133d60942a057646f9b866de5cb0ebb3ddf6109186f6c026508) |
| run-009 | 174 | de-risk | 70 | 5 | 1 | 6 | [0x5a11d372](https://sepolia.basescan.org/tx/0x5a11d372709fd188afb6304a0bddb8b5a47260b7057ae6c4ca0999549e234b0c) | [0x4cadd2a2](https://sepolia.basescan.org/tx/0x4cadd2a26589508909078bf96da9a62ae96431f46c0fb18485c8ac92f197bba9) |
| run-009 | 177 | re-risk | 30 | 59 | 2 | 61 | [0xd0541b8e](https://sepolia.basescan.org/tx/0xd0541b8ece028be39eebfd119cfb3df10c48b46928deb2169074e9b06749dbed) | [0x375d7f6d](https://sepolia.basescan.org/tx/0x375d7f6d23d5dd60b9fa2629cf8d96027be6864c47005ac02e23478936823350) |
| run-010 | 179 | de-risk | 70 | 6 | 1 | 7 | [0x2a2898d5](https://sepolia.basescan.org/tx/0x2a2898d55e8bc1b350de6c5f4fbbb0f304b4a58c4617e2be4a7ca5472e42f0dd) | [0xe70acaed](https://sepolia.basescan.org/tx/0xe70acaed414e09a399e14368d9907de07800a7a84dcede28e9d2debe96aa86cf) |
| run-010 | 182 | re-risk | 30 | 83 | 1 | 84 | [0xdb688164](https://sepolia.basescan.org/tx/0xdb68816469ae8bb43a34c4d64346d937bc409c450a03271a6d47cf395fb9c197) | [0x9c928488](https://sepolia.basescan.org/tx/0x9c9284885a4d1380810a8c218d7c20962a401f0997856301adde53baccac5239) |
| run-011 | 185 | de-risk | 70 | 5 | 1 | 6 | [0x1cd578f8](https://sepolia.basescan.org/tx/0x1cd578f8acc591c7de3c288fbbe40ae42ab069786bfdd1a68d1cb482cd0d3e01) | [0x6a8b82f2](https://sepolia.basescan.org/tx/0x6a8b82f22ec8f3fdd9c0e9597e20c73c7f762990a69a7bcbb06ba34ed9c3ab9f) |
| run-011 | 188 | re-risk | 0 | 58 | 2 | 60 | [0x10a8f35f](https://sepolia.basescan.org/tx/0x10a8f35fc915555cfc46292c7b97b19cdb8c1987666dd7d1d8fc26082a9415f4) | [0x03cd4037](https://sepolia.basescan.org/tx/0x03cd4037ff725f396424eaae7fa3a819e297b7ee88c711b7bfb965825ab59993) |
