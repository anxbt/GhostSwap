# Handoff: GhostSwap Emergency Resolution

## Goal
Add emergency resolution features to an on-chain encrypted swap protocol (GhostSwap) so users can recover funds when the CoFHE coprocessor stalls. This covers: `cancelStuckSwap` (6h), `autoReleaseStuckSwap` (24h), `cancelStuckAuction` (1h), and `publishDecryptResult` with ECDSA signature verification from a trusted verifier.

## Current State
Phases 1–4 are complete. 80 tests passing. Frontend builds cleanly. Phase 5 (live Sepolia E2E) is the only remaining work.

**Contracts** — All emergency functions implemented in `PostSettleRevealHook.sol` with `EmergencyResolved` enum state, timeout constants, and ECDSA sig verification against `COFHE_VERIFIER` immutable address.

**Frontend** — Error handling module, CoFHE health hook, decrypt poller hook, cancel/auto-release buttons, and emergency state display all wired into `GhostSwap.jsx`. ABI updated with new functions and events.

**Deployment** — `Deploy.s.sol` ready for Arbitrum Sepolia with env vars for `COFHE_VERIFIER_ADDRESS`, `SWAP_ROUTER`, `VAULT_ASSET_TOKEN`, etc.

**Tests** — 33 unit tests + 6 emergency integration tests + 1 original integration test + 40 other = 80 total, all passing.

## Files in Flight

### Changed
- `packages/contracts/src/interfaces/IPostSettleRevealHook.sol` — `EmergencyResolved` state, `AuctionCancelled` flag, new function signatures with signature params, new events
- `packages/contracts/src/hooks/PostSettleRevealHook.sol` — `cancelStuckSwap`, `autoReleaseStuckSwap`, `cancelStuckAuction`, `publishDecryptResult` with ECDSA verification, `COFHE_VERIFIER` immutable, timeout constants (`CANCEL_DELAY_BLOCKS=1800`, `FALLBACK_DELAY_BLOCKS=7200`, `AUCTION_TIMEOUT_BLOCKS=300`)
- `packages/contracts/test/PostSettleRevealHookTest.t.sol` — 15 new emergency tests, `MockZkVerifierSigner` helper
- `packages/contracts/test/Integration.t.sol` — constructor updated for `cofheVerifier`
- `packages/contracts/test/EmergencyIntegration.t.sol` — **new file**, 6 full-lifecycle integration tests
- `packages/contracts/foundry.toml` — `via_ir = true`, optimizer 200 runs (fixes stack-too-deep)
- `packages/contracts/script/Deploy.s.sol` — accepts `cofheVerifier` param
- `packages/contracts/script/LocalSetup.s.sol` — passes mock verifier address
- `fe/src/lib/errorHandling.js` — **new file**, maps contract/CoFHE errors to user messages
- `fe/src/hooks/useCoFheHealth.js` — **new file**, polls CoFHE coprocessor health
- `fe/src/hooks/useDecryptPoller.js` — **new file**, tracks block-based cancel/auto-release timeouts
- `fe/src/GhostSwap.jsx` — wired `decodeError`, cancel/auto-release handlers, poller status in `PendingRevealPanel`, CoFHE health dot in footer, `EmergencyResolved` state handling
- `fe/src/lib/postSettleRevealAbi.js` — added `cancelStuckSwap`, `autoReleaseStuckSwap`, `cancelStuckAuction`, `publishDecryptResult`, timeout view functions, new events

### Failed Attempts
- **Stack-too-deep in test file** — Adding signature verification tests blew past Solidity's stack limit. Fixed by enabling `via_ir = true` in `foundry.toml` with optimizer at 200 runs. Considered refactoring tests to use fewer locals but `via_ir` was cleaner.
- **Integration test constructor mismatch** — After adding `cofheVerifier` to the hook constructor, `Integration.t.sol` and both deployment scripts (`Deploy.s.sol`, `LocalSetup.s.sol`) failed. All three needed the new parameter passed through.

## Next Step
**Phase 5: Live Arbitrum Sepolia E2E test.** Deploy the contracts to Arbitrum Sepolia using `Deploy.s.sol` with a real `COFHE_VERIFIER_ADDRESS`, run an encrypted swap through the full lifecycle on testnet, and record a demo. You'll need:
1. Set env vars: `PRIVATE_KEY`, `COFHE_VERIFIER_ADDRESS`, `SWAP_ROUTER`, `VAULT_ASSET_TOKEN`, `ARBITRUM_SEPOLIA_RPC`
2. `forge script script/Deploy.s.sol:DeployScript --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast`
3. Update frontend `.env` with deployed contract addresses
4. Run a swap through the UI, wait for reveal, verify cancel/auto-release buttons appear at correct timeouts
5. Record demo