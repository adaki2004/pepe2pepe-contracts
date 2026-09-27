# Pepe2Pepe contracts

Fully collateralized, fixed-odds P2P betting with FIFO shared backing. Exact deployed sources, compiler inputs and deployment manifests; no frontend, backend or private configuration.

## Deployments

| Contract | Ethereum (1) | Robinhood (4663) |
| --- | --- | --- |
| OfferSupport | [`0xfac58A7AB57176D5c10D6a7862C93b50c1B43CE7`](https://etherscan.io/address/0xfac58A7AB57176D5c10D6a7862C93b50c1B43CE7#code) | [`0x24f4A843cD688FA7961B98DeAec3CaE0571B404C`](https://robin.etherscan.io/address/0x24f4A843cD688FA7961B98DeAec3CaE0571B404C#code) |
| BackingQueue | [`0x16A167E745497b3E308E81492bc1b6a93A620929`](https://etherscan.io/address/0x16A167E745497b3E308E81492bc1b6a93A620929#code) | [`0x0852dC585f7E0c1bC2F0F198fD907Cd668BeD984`](https://robin.etherscan.io/address/0x0852dC585f7E0c1bC2F0F198fD907Cd668BeD984#code) |
| ImdOracleAdapter | [`0x93a9DD050892EC7CeDCa8825FE655Da53DbC1388`](https://etherscan.io/address/0x93a9DD050892EC7CeDCa8825FE655Da53DbC1388#code) | [`0xfc91C1A8482acf3bE973dAee66e13Ac82b4c19c7`](https://robin.etherscan.io/address/0xfc91C1A8482acf3bE973dAee66e13Ac82b4c19c7#code) |
| Pepe2PepeMarket | [`0x54F97d8b32d8E90770d76B7d9eEDE1B77E28E3B8`](https://etherscan.io/address/0x54F97d8b32d8E90770d76B7d9eEDE1B77E28E3B8#code) | [`0x412F9b71c119Aee1bec6331a7Cb7Bb5c4fa1518B`](https://robin.etherscan.io/address/0x412F9b71c119Aee1bec6331a7Cb7Bb5c4fa1518B#code) |

All eight contracts (both libraries, market and Oracle adapter on each chain) are explorer-verified as of 27 September 2026; see each explorer and the dated status snapshots. The contracts are shared by staging and the intended production app; TP20 is a testing asset, not a separate custody deployment.

## Reproduce

Node.js 22+:

```sh
npm ci --ignore-scripts
npm run build
# Optional independent comparison against a node on the chosen chain:
RPC_URL=https://your-ethereum-node npm run verify:chain -- 1
RPC_URL=https://your-robinhood-node npm run verify:chain -- 4663
```

Solidity **0.8.37+commit.f401782d**, optimizer **1 run**, **viaIR**, **Cancun**, metadata bytecode hash **none**. Dependencies are embedded unchanged in the standard JSON inputs, with their license headers. `src/` is checked byte-for-byte against those inputs before compilation. Package versions and integrity hashes are locked.

The offline build verifies all eight complete **creation bytecode + constructor argument** Keccak-256 hashes and deployment addresses. The optional node check also compares the actual mined deployment input, successful receipt, full runtime hash and compiled runtime template. Solidity immutables are constructor-initialized; only compiler-listed immutable spans are normalized in the template check, while the full runtime hash is compared separately. Libraries have their own address embedded in a delegate-call guard, whose value is checked explicitly. A plain hash of an unlinked, uninitialized artifact is therefore not the deployed runtime hash. No transactions are sent.

## Trust and review

Creation is permissionless. Fixed accepted returns and separate unused collateral are enforced on-chain. Authorized operators may replace requests, emergency-VOID or set YES/NO/VOID **before finalization**. Admins can change configuration for future actions; inspect the source and live roles. Oracle votes and human oversight do not guarantee truth or safety.

`reports/` contains existing AI-assisted review output and a later FIFO implementation review. The earlier scan covered a pre-FIFO candidate and returned 8 of 12 requested specialist reports. These are **not an independent external audit**, nor a new audit of the deployed FIFO code. No additional audit was run for this publication.

The separately preserved `reports/PASHOV_AI_LEGACY_SCOPE_20260927.md` reports no findings but explicitly lists the older pari-mutuel files, including `PepedictionMarket.sol`. Its scope does **not** establish an audit of the current `Pepe2PepeMarket` FIFO deployment.
