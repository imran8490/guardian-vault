# Execution proof (Week 1 loop)
Networks: Base Sepolia (84532), Reactive Lasna (5318007)
Deployer: 0xcefa779a10FF61f13614ADc86CC94a7Ba75aA08C

## Contracts
- HelloOrigin (Base): 0x17cfa20820a1Ac55dF23427DE51691D24a9F05DF
- HelloReactive (Lasna): 0x17cfa20820a1Ac55dF23427DE51691D24a9F05DF
- HelloCallback (Base): 0xd6B892b389029ea69E44609d8A620f9E51Dd29F8

## Transactions
- ping (Base, block 57204490): 0x2a917b3abec01a68685503e82c0bcb9fbdaeb04242d982aa9d8e9beb64268e2c
- react (Lasna, block 8047987): 0x491e37b82c3613fafc5e308382302c2fa12711af8d0bdfdf5f31648b5e14b661
- onPong callback (Base, block 57204499): 0xdb6706b537ce4bbf5849763eb4eff9e4a181b8a3fa23d421072797a55816f515

## Result
reactCount=1, pongCount=1, lastValue=42

## Latency (block timestamps, 1s resolution)
ping=1794362766  react=1794362766  callback=1794362768
ping->callback total: 2s

## Week 2: Guardian Vault live loop (epoch 1, de-risk)
Contracts: VOL=0x14d5BCdd6D00398ab5c26a8f88507dB149669992 STABLE=0x16F827f4a6848d93cAb55d04bFeAE9e80AF20ea9 POOL=0x9992fB4FF288FA112d1bA4e4d70c67406b58390E ORACLE=0x10E4eF88f1A4f82823198868d99756e0F118FB37
Reactive (Lasna)=0x14d5BCdd6D00398ab5c26a8f88507dB149669992 Vault (Base)=0x5caC898a90BA6Ea29e2d0fE3CF41e02b1d8265Df
PublishRisk (Base, block 57312299): 0x125a77b1a4375749335fa9df8254e7b4ec08712600e77f0d447943737ccd57e4
ActionRequested (Lasna, block 8068302): 0x4f3e57e0a3e3e87ca55c2f747dc603e34e3400e513d0fdf81ae8a57abd72c251
DeRisked callback (Base, block 57312309): 0x41a8814bc848149aa0466ba21713d329f9ed0b5c7613edd55d363f1a856ab504
Result: riskOff=true, 100 gVOL sold for 44.06 gUSD, score 92
Timestamps: publish=1794384328 lasna=1794384328 callback=1794384330, publish to callback = 2s
Note: Lasna and Base clocks differ, so only the Base-to-Base total is a clean number.

## Week 2: re-risk (epoch 2, score 15)
PublishRisk (Base, block 57315874): 0x5b5bbe6e678732360b1bd5f220cf45e8a9e58eae4b637d9497fcd32ed66f2f55
ActionRequested deRisk=false (Lasna, block 8068977): 0x92f7c6dd7e3268334e9fc80fa9e062ca6b76b4968ff0f13266d5c96af08efdcc
ReRisked callback (Base, block 57315883): 0xf167e050f3e5cdf16ebca9582c314cc2c8cf30d08c4b4288d68cb5deb95bad49
Result: riskOff=false, vault bought back 44.45 gVOL with 44.06 gUSD
Publish to callback = 2s
Honest note: pool was already crashed (price 0.44) when the verdict came, so the vault sold low and bought back after recovery: 100 gVOL -> 44.45 gVOL. The loop works; the demo scenario needs the AI to react earlier (week 3: staged crash).
