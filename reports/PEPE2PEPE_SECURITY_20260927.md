# One security scan — 27 September 2026

[Unmodified generated report](PEPE2PEPE_SECURITY_RAW_20260927.md). This companion
records coverage and subsequent remediation separately from the scan's output.

Scope: new `Pepe2PepeMarket`, `OfferTypes`, `OfferSupport`, shared market storage,
types/math/UTF-8 validation and existing `ImdOracleAdapter`; backend ingestion
inspected as a consumer dependency. Frozen base ae513e3 plus uncommitted candidate.
The `solidity-auditor` skill's requested single scan returned **8 of 12** specialist
reports. Math, access, economic, invariant, first-principles, numerical, trust and
flow reviews returned. Execution, periphery, asymmetry and boundary specialists
failed before final reports. A flow review's later formatting follow-up failed;
its original full finding was counted. No additional scan was run.

## Confirmed finding and remediation

**NUL text can block other users' event records (confidence 90).** Public creator
text previously admitted U+0000 through valid UTF-8, including the 32-byte ASCII
fast path. PostgreSQL JSONB rejects escaped NUL. A batched webhook containing that
event can therefore block unrelated canonical events before staging/projection.
Several returned reviews independently identified the same cause.

Fixed in the new support library: reject NUL across every byte of question,
rules and URI inputs, including request/recovery URI paths. Legacy `Utf8.sol`
was left unchanged to avoid silently altering preserved custody. Regression
coverage includes every possible NUL offset in a 256-byte field, all three
creation fields, and settlement/emergency reason URI rejection. One test UUID
was corrected to the existing left-aligned encoding so it actually reaches the
URI check. Tests pass. The remediation was tested, not independently re-audited.

## Policy leads, not confirmed unauthorized transfers

- The pool cap excludes fewer than one complete maker lot of residual collateral.
  The implementation caps matchable exposure; residual returns after STOP. No
  loss of other users' principal was established. This scope is documented.
- A tiny first match earns the full service fee, including a match placed by the
  beneficiary or a related wallet. This follows the unconditional first-match
  earning rule. It is an economic trust assumption, disclosed before creation,
  not proof that the Oracle was paid. Oracle dispatch still waits until Ask.

The private working report and source hashes remain in the ignored local folder
`.solidity-auditor/runs/20260927-055004/`. This tracked document records the actual
coverage and fix. It is an AI-assisted code review, not an independent external
audit or a guarantee that the contracts are free of vulnerabilities.
