# 🔐 Security Review — Pepe2PepeMarket

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/Pepe2PepeMarket.sol` · `src/OfferTypes.sol` · `src/OfferSupport.sol`<br>`src/MarketStorage.sol` · `src/MarketTypes.sol` · `src/ParimutuelMath.sol`<br>`src/Utf8.sol` · `src/ImdOracleAdapter.sol` |
| **Confidence threshold (1-100)** | 75 |

---

## Findings

[90] **1. NUL text can block other users’ event records**

`OfferSupport.validateCreation` · Confidence: 90

**Description**
Any creator can insert NUL into market text, so PostgreSQL rejects the event batch and omits other users' markets.

**Fix**
Reject NUL in every creator text field and URI before the contract stores terms or emits events.

Cover both the scalar and 32-byte ASCII paths if changing `Utf8.validate`; a scalar-only NUL check leaves the fast path vulnerable.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | NUL text can block other users’ event records |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Pool cap excludes collateral below one complete lot** — `Pepe2PepeMarket._checkCapacity` — Code smells: cap ignores an incomplete maker lot. A creator can leave fewer than 9,999 unmatched units outside the cap; no other-user loss is established. The intended cap scope needs confirmation.
- **Service recipient can earn its credit through a small first bet** — `Pepe2PepeMarket.matchBet` — Code smells: full service credit follows any first match. The service recipient can fund that match itself; the documented earning policy permits this, and no separate unauthorized transfer is established.

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
