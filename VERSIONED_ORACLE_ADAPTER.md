# Versioned Oracle adapter

Live since 2 October 2026. Both adapters are the production defaults for future
markets (platform configuration version 6):
[Ethereum activation](https://etherscan.io/tx/0x75eba33ad23576275ab31e687054245f9107f7501cc51e2f56fe2eb137995892),
[Robinhood activation](https://robin.etherscan.io/tx/0xfb1e64950f609d1b0d598557d95cde3966b5819e17646f92407916bc0b3e35b0).
Existing markets retain their original adapters. The separate TP20-only staging
custody was not migrated in this rollout.

The market's existing `settleMarket(id, bytes proof)` interface is unchanged.
`VersionedImdOracleAdapter` is a stable-address, non-proxy implementation of
`IOracleAdapter`. The v2 codec decodes and hashes the actual IdentityMD message,
including signed `panelSize`, `quorum` and `agreed` fields. The router recovers
the immutable trusted signer itself, using its own address as verifyingContract.

The initial accepted format is v2. A v1 signature does not sign quorum counts and
cannot bypass this router's immutable minimum: a panel of at least 100, quorum
at least 67 and strictly greater than two thirds of panelSize, with agreed at
least quorum and no more than panelSize. The legacy adapter remains available
for old markets. This authenticates one trusted aggregate signer, not independent
worker signatures, objective truth or Ethereum consensus.

The router uses STATICCALL codecs, never delegatecall. It checks exact committed
question/rules/URI, reconstructed canonical document, market/id/terms, source
chain/window, request UUID, consumer chain, outcome encoding and proof validity.
The public question omits metadataURI as before. Custody controls finalization,
replay protection and payouts. A permissionless relayer cannot redirect winnings.
Back-office approval only gates the platform's relayer. If custody publicFinalization
is enabled, anyone may submit a valid proof without that approval, including before
human review or despite a backend Hold. No on-chain challenge period is provided,
and an operator cannot rewrite a finalized result. Public finalization remains off
in this rollout.

The initial owner is the existing admin wallet, with two-step ownership transfer.
The service wallet is not the owner. Adding a previously unused version requires
an owner proposal, a fixed 48-hour delay, then activation executable by anyone.
Proposals can be cancelled/replaced (replacement restarts the delay). An installed
version cannot be replaced; the owner can permanently disable it immediately.
Every change emits events and pins the module runtime hash and schema hash.

Codec governance remains a trust assumption: a malicious codec can lie about
which fields its struct hash authenticates. Code-hash pinning cannot detect a
proxy's implementation-storage changes. Only reviewed immutable non-proxy codecs
should be registered, and multisig ownership is recommended. The stable policyHash
explicitly describes this governed model. The notice period does not create an
early withdrawal right for matched bets. Renouncing ownership is irreversible;
already queued proposals can still be activated, so cancel them first if freezing
configuration is intended.

Future formats require an explicitly reviewed codec and compatible backend parser.
They can preserve the router and custody addresses while satisfying the immutable
core policy. Changing the signer or fundamental policy still requires a different
adapter for future markets. Existing markets cannot be moved merely by changing
`defaultOracleAdapter`; old signatures cannot be rebound to a new adapter address.

All four new contracts are verified; exact compiler inputs, constructor arguments,
transaction hashes and runtime hashes are included in `deployments/`. The offline
build reproduces all twelve deployments. Implementation checks include 71 Foundry
tests (invariants and binding fuzz tests), real-provider/independent wire vectors,
99 Rust tests, 10 signer tests and local two-chain settlement integration. These
are not an independent external audit; the older AI reports do not cover this new
adapter. No live market, bet, Oracle purchase, settlement or VOID was created as a
release smoke test.
