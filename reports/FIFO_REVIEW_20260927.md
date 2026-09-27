# FIFO local review — 27 September 2026

Focused implementation review and executable checks for this local change, not
an independent audit. The earlier `PEPE2PEPE_SECURITY_20260927.md` reviewed the
single-maker candidate; its findings are not evidence that FIFO was audited.

## Invariants checked

- Sum of all matched entitlements, unused principal, remaining fee reserves,
  service escrow and accrued credits equals the asset liability and custody
  balance. Three-market stateful runs share a collateral ledger.
- Tickets form a strictly increasing, nonoverlapping prefix. Returning owners
  cannot inherit earlier priority. Exact lots yield fully funded fixed returns;
  later backing cannot dilute prior takers.
- Fee-prefix differences equal the sum of each ticket's cumulative rounded
  matched fee. Mixed deposit-time rates, fee changes, split fills, zero rates,
  extreme prices and arbitrary refund order conserve reserves.
- Per-wallet unmatched charges accumulate rounded unused principal up to the
  market's snapshotted cap. A ticket's reserved unmatched charge always covers
  its incremental charge. Surplus is returned to the ticket owner.
- Ticket 0 alone can recover the service escrow, only if no match occurred.
  First match earns exactly one fixed service credit; it does not ask the Oracle.
- Matched and unused claim flags are independent; effects precede transfers.
  Rejected native/token transfers revert flags, cap accounting and liabilities.
  A blocked recipient cannot stop another owner's individual claim.
- The custody reentrancy guard covers linked library calls and all monetary
  paths. Libraries cannot upgrade, hold separate funds or grant their own roles.
  Admin/relay/Ask/unresolved checks remain in custody before support settlement.
- Oracle replacement retains the canonical question hash and old replay keys.
  Public relay still needs a valid proof. Emergency/override remain separately
  gated and cannot alter a terminal result. Changing the default adapter affects
  only future markets.
- Runtime configuration enforces uint128 monetary bounds. Full offered exposure
  includes both sides; all narrowing of externally funded amounts is checked.
  Positive exact lot sizes plus the minimum prohibit zero-length tickets.
- 50 includes creation and repeated owners. No linear scan on matching;
  individual claims have bounded work; optional batches are limited to 20.

## Executed coverage

59 Solidity tests across six suites, including five 512-case fuzz tests and two
128-run, 64-action invariants. Tests cover the Alice/Bob/Alice order, all outcomes,
50-ticket full crossing and rejected ticket 51, native ETH, ordinary/no-return/
taxed/surcharge/blocked/callback tokens, negative-rebase solvency protection,
permissions, changed defaults, recipient splits, request replay and adapter proofs.
The fee/payout fuzz reference calculates ticket entitlements independently of the
library's prefix lookup. The stateful harness alternates creator/another backer,
two opposing wallets, fee changes, time, outcomes and refund ordering.

Independent JavaScript signature/canonicalization fixtures pass five wire tests.
Two unsigned-deployment tests check library linking, role separation, fee/cap
configuration and unsafe plan rejection. The local broadcaster recovery test
interrupts after pause, resumes its journal, repeats a completed deployment,
and rejects tampered journals/provisional runtime wallets without a duplicate.
Both-chain fork rehearsal uses real token code and verifies transfers, partial
matching, VOID, unused/service/fee claims and zero residual liabilities.
Exact current gas/size/build evidence is in `FIFO_GAS.md` and deployment reports.

## Deliberate tradeoffs and limits

- This adds custody complexity. Top-ups and unused refunds cost more than the
  single-maker baseline; ticket independence and per-wallet caps require storage.
- The ticket cap is a lifetime cap, so one wallet can consume many slots. The
  configured deposit minimum makes that funded behavior, not a per-person limit.
- Queue priority is execution order. Transactions can race/reorder; identity or
  mempool arrival is not a guaranteed place. An over-capacity opposing bet
  reverts rather than silently becoming a partial fill.
- Fee reserve is conservatively funded per ticket. The wallet cap is honored at
  refund time; separate tickets may temporarily reserve more than that cap.
- First match earns the entire service fee even if it never pays for useful
  resolution. Related wallets can match; identity controls do not prove independence.
- Smart-wallet ETH receivers must accept payment. Unsupported/rebasing/blacklisted
  tokens can prevent transfers; exact-transfer and solvency checks do not make
  arbitrary ERC20 behavior safe. Asset allowlisting still requires review.
- Public creation/known information/late trading and subjective wording remain
  market design risks. Oracle/operator correctness and response availability are
  not proven by these accounting tests. There is no automatic response timeout.
- No FIFO BE migration, production ingestion replay or browser E2E was performed
  in this contract-only phase. The real receipt fixture and handoff define those
  next checks. No live custody transactions were sent.
