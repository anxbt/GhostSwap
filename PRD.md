# GhostSwap PRD

**Private swap execution on Uniswap v4. Encrypted reservation prices, solver auctions on ciphertext, surplus recapture to vault depositors.**

| Field | Value |
|---|---|
| Version | 1.0 |
| Network | Arbitrum Sepolia |
| Date | May 2026 |
| Program | Fhenix x AKINDO Buildathon |
| Status | Wave 4 → Wave 5 |
| Tests | 54 passing on Anvil |

---
/p
## 1. Problem Statement

Every swap on every transparent DEX broadcasts `amountOutMinimum` in plaintext before settlement. Solvers read the floor and fill at it, keeping the surplus. This is solver-side price extraction: legal, invisible, systematic.

**Why FHE:** ZK proofs require the solver to decrypt before computing. TEEs trust hardware. FHE computes directly on ciphertext. The solver never decrypts the minimum. The guarantee is mathematical.

**Why the vault exists:** A hook alone is forkable in one afternoon. Vault + hook are mutually dependent. Fork the hook without vault: no depositors, no TVL. Fork vault without hook: no encrypted execution, no surplus. Neither works alone. That is the moat.

### Comparison Table

| | Without GhostSwap | With GhostSwap |
|---|---|---|
| Market price | 3,300 USDC/ETH | 3,300 USDC/ETH |
| Your floor | Visible: 3,100 USDC | Encrypted: \[redacted\] |
| Solver fills at | 3,101 USDC (reads your floor) | 3,250 USDC (must compete honestly) |
| You receive | 3,101 USDC | 3,250 USDC |
| Surplus captured | 0 USDC (solver keeps 199 USDC) | 150 USDC flows to vault depositors |

---

## 2. System Architecture

```
BROWSER (fe/)
  User enters swap.
  @cofhe/sdk encrypts amountOutMinimum client-side.
  ctHash + EIP-712 signature encoded into hookData.
  Submitted via swapRouter.swap().

PostSettleRevealHook.sol
  beforeSwap: validates EIP-712 sig (EOA + ERC-1271), stores euint128, grants FHE access.
  afterSwap: queues FHE.gte comparison, records settlement, starts 15-block timer.
  finalizeSlippageCheck: reads async CoFHE result, routes surplus to vault.
  revealSwapDetails: enforces delay, releases trade details to permitted address.

GhostVault.sol
  Holds depositor funds.
  recordSurplus() distributes surplus proportionally to shareholders at time of swap.
  claimSurplus() lets depositors withdraw yield.
  deposit()/withdraw() manage shares.
  Idempotent -- SurplusAlreadyRecorded prevents double-recording.

GhostVaultPeriphery.sol
  Manages execution channel between vault and hook.
  Enforces auction winner binding via getAuctionExecutionBinding().
  Only the winning solver can call executeIntent().
  Supports intent queue with cancellation and expiry.

Fhenix CoFHE Coprocessor
  Off-chain async processor.
  Receives FHE.decrypt() requests from hook.
  Returns results via FHE.getDecryptResultSafe().
  Executes FHE.gte, FHE.max, FHE.eq on ciphertext without ever decrypting the values.
```

---

## 3. Lifecycle State Machine

| State | Trigger | Description |
|---|---|---|
| `DraftIntent` | Initial | User prepares encrypted intent off-chain |
| `IntentCaptured` | via `beforeSwap()` | EIP-712 verified, euint128 stored, FHE access granted |
| `SettledPendingReveal` | via `afterSwap()` | Settlement recorded, FHE comparison queued, timer started |
| `DecryptReady` | Time-gated | `block.number >= decryptReadyBlock` (default +15 blocks) |
| `RevealedToAuthorized` | Final (normal) | Trader or authorized revealer called `revealSwapDetails()` |
| `EmergencyResolved` | Final (failure) | Fallback triggered: cancel (6h), auto-release (24h), or auction cancel |

### Emergency Failure Paths

| Scenario | Delay | Who Calls | Outcome |
|---|---|---|---|
| A — Auto Release | 24 hours | Anyone | Floor amount released to trader. Vault gets nothing. State: `EmergencyResolved`. |
| B — Auction Cancel | 10 minutes | Trader only | Auction voided. No swap executed. Input tokens returned. Retry on standard Uniswap. |
| C — Manual Cancel | 6 hours | Trader only | Swap voided. Input tokens returned to trader. Confirmation modal required. |

**Priority rule:** Trader funds always take precedence over vault yield. In every emergency scenario, vault depositors receive no surplus from the affected swap. Depositors accepted risk when depositing. The trader did not.

---

## 4. Implementation Status

### 4.1 Built and Tested (54 tests passing on Anvil)

| Component | Status | Notes |
|---|---|---|
| Hook lifecycle: beforeSwap → afterSwap → reveal | ✅ DONE | All state transitions correct |
| EIP-712 signed intent validation | ✅ DONE | EOA and ERC-1271 (multisig) support |
| Nonce replay protection | ✅ DONE | Prevents double-spend attacks |
| FHE.gte slippage comparison queued in afterSwap | ✅ DONE | `_queueSlippageCheck` implemented |
| finalizeSlippageCheck + surplus enforcement | ✅ DONE | Reads async CoFHE result, routes surplus |
| 15-block reveal delay enforced onchain | ✅ DONE | `decryptReadyBlock` set in afterSwap |
| Solver auction: submitBid, queue, finalize | ✅ DONE | FHE.max winner selection working |
| Solver allowlist registration | ✅ DONE | `registerSolver` / `unregisterSolver` |
| Auction winner execution binding in periphery | ✅ DONE | Only winner can call `executeIntent()` |
| GhostVault deposit/withdraw + share accounting | ✅ DONE | Idempotent `recordSurplus` |
| GhostVault surplus distribution to depositors | ✅ DONE | `cumulativeSurplusPerShareX18` pattern |
| GhostVaultPeriphery intent queue + cancellation | ✅ DONE | Queue, execute, cancel all tested |
| Frontend @cofhe/sdk encryption wired | ✅ DONE | Real SDK, not mock. `cofhejs` removed. |
| Frontend `revealSwapDetails()` calling real contract | ✅ DONE | Not simulated |
| Block countdown from real chain block numbers | ✅ DONE | Derived from `decryptReadyBlock` |

### 4.2 Missing — Must Implement

**P0 items block production deployment. Build in order listed.**

| Priority | Item | File | Status |
|---|---|---|---|
| P0 | `cancelStuckSwap()` | `PostSettleRevealHook.sol` | ❌ NOT BUILT |
| P0 | `autoReleaseStuckSwap()` | `PostSettleRevealHook.sol` | ❌ NOT BUILT |
| P0 | `cancelStuckAuction()` | `PostSettleRevealHook.sol` | ❌ NOT BUILT |
| P0 | `publishDecryptResult` signature verification | `PostSettleRevealHook.sol` | ⚠️ PLACEHOLDER |
| P0 | `Deploy.s.sol` for Arbitrum Sepolia | `script/` | ❌ NOT BUILT |
| P0 | `EmergencyResolved` in SwapState enum | `IPostSettleReveal.sol` | ❌ NOT BUILT |
| P1 | Frontend `decryptForTx` + `publishDecryptResult` | `GhostSwap.jsx` | ❌ NOT BUILT |
| P1 | `errorHandling.js` — full error map | `fe/src/lib/` | ❌ NOT BUILT |
| P1 | `useCoFheHealth.js` — health check | `fe/src/hooks/` | ❌ NOT BUILT |
| P1 | `useDecryptPoller.js` — timeout logic | `fe/src/hooks/` | ❌ NOT BUILT |
| P1 | Cancel button UI (Scenario C, after 6h) | `GhostSwap.jsx` | ❌ NOT BUILT |
| P1 | Auto-release UI (Scenario A, after 24h) | `GhostSwap.jsx` | ❌ NOT BUILT |
| P1 | Tests for emergency functions | `test/` | ❌ NOT BUILT |
| P1 | Tests for `publishDecryptResult` flow | `test/` | ❌ NOT BUILT |
| P2 | Gas benchmarks vs standard Uniswap | `docs/` | ❌ NOT BUILT |

---

## 5. FHE Operations Reference

| Operation | Called In | Purpose |
|---|---|---|
| `FHE.asEuint128(InEuint128)` | `beforeSwap` | Convert client ciphertext to onchain encrypted type |
| `FHE.allowThis(euint128)` | `beforeSwap` | Grant hook contract access to ciphertext |
| `FHE.allow(euint128, address)` | `beforeSwap` | Grant trader wallet access to ciphertext |
| `FHE.gte(euint128, euint128)` | `_queueSlippageCheck` | Compare actual output >= encrypted minimum |
| `FHE.decrypt(euint128)` | `afterSwap`, `queueSolverAuction` | Request async decryption from coprocessor |
| `FHE.getDecryptResultSafe(euint128)` | `finalizeSlippageCheck` | Poll for async result without reverting |
| `FHE.max(euint128[])` | `queueSolverAuction` | Find winning encrypted bid |
| `FHE.eq(euint128, euint128)` | `queueSolverAuction` | Identify which solver submitted winning bid |

### SDK Reference — `@cofhe/sdk` (`cofhejs` is DEPRECATED, do not use)

```ts
// Initialization
import { createCofheConfig, createCofheClient } from '@cofhe/sdk/web';
import { chains } from '@cofhe/sdk/chains';

const config = createCofheConfig({ supportedChains: [chains.arbitrumSepolia] });
const client = createCofheClient(config);
await client.connect(publicClient, walletClient);

// Encrypt before transaction
import { Encryptable } from '@cofhe/sdk';
const [encMinOut] = await client
  .encryptInputs([Encryptable.uint128(minOutRaw)])
  .execute();

// Decrypt for UI display (view only, no onchain sig)
import { FheTypes } from '@cofhe/sdk';
const value = await client
  .decryptForView(ctHash, FheTypes.Uint128)
  .execute();

// Decrypt for onchain publishing (NEW — was not in cofhejs)
const { decryptedValue, signature } = await client
  .decryptForTx(ctHash)
  .withoutPermit()
  .execute();

await hook.publishDecryptResult(ctHash, decryptedValue, signature);

// Error handling
import { isCofheError } from '@cofhe/sdk';
try {
  const [enc] = await client.encryptInputs([Encryptable.uint128(val)]).execute();
} catch (err) {
  if (isCofheError(err)) {
    console.error(err.code);    // CofheErrorCode enum
    console.error(err.message); // human-readable string
  }
}
```

---

## 6. Error Handling Architecture

Never show raw errors. Every error must be decoded to a specific actionable message. Three error surfaces exist.

### 6.1 Contract Custom Errors

| Custom Error | User-Facing Message |
|---|---|
| `FillBelowEncryptedMinimum` | Fill price was below your minimum. Your funds are safe. |
| `DecryptNotReady` | Waiting for encrypted result. Try revealing in a few blocks. |
| `IntentAlreadyExists` | You have a pending swap. Wait for it to resolve first. |
| `NonceAlreadyUsed` | This intent was already submitted. Create a new swap. |
| `DeadlineExpired` | Your swap intent expired. Please try again. |
| `UnauthorizedRevealer` | Only the trader or approved compliance address can reveal. |
| `CancelDelayNotElapsed` | Cancel window not open yet. Available after 6 hours. |
| `FallbackDelayNotElapsed` | Auto-release not available yet. Available after 24 hours. |
| `InvalidCoFHESignature` | Encrypted result signature is invalid. Do not proceed. |
| `SurplusAlreadyRecorded` | This swap surplus was already distributed. |

### 6.2 CoFHE Health States

| Status | Indicator | User Message | UI Action |
|---|---|---|---|
| healthy | 🟢 Green dot | Privacy service online | Normal operation |
| degraded | 🟡 Amber dot | Privacy service responding slowly | Show warning, allow swap |
| offline | 🔴 Red dot | Privacy service offline — funds safe | Warn, offer standard swap |
| checking | 🟡 Pulsing dot | Checking privacy service... | Disable swap button |

### 6.3 Decrypt Polling Timeline

| Elapsed | Status | Key Message to User | UI Action |
|---|---|---|---|
| 0 to 2 min | `waiting` | Verifying encrypted fill... (Ns) | Normal — keep polling |
| 2 to 6 hours | `coprocessor_delayed` | CoFHE taking longer than expected. Funds are safe. | Show warning banner |
| 6 to 24 hours | `stuck_cancellable` | You can cancel this swap and reclaim your ETH. | Show cancel button (Scenario C) |
| 24h+ | `auto_release_available` | Auto-release available. Claim your funds. | Show claim button (Scenario A) |

---

## 7. Build Order — Wave 5

Work in this exact order. Do not skip steps. P0 must complete before P1.

### Week 1 — Contract Gaps

| Day | Task |
|---|---|
| Day 1 | Add `EmergencyResolved` to `SwapState` enum in `IPostSettleReveal.sol`. Add `AuctionCancelled` to auction state enum. Add `CANCEL_DELAY_BLOCKS` (1800), `FALLBACK_DELAY_BLOCKS` (7200), `AUCTION_TIMEOUT_BLOCKS` (300) as constants. |
| Day 2 | Implement `cancelStuckSwap()` — Scenario C. Test: `beforeDelay_reverts`, `afterDelay_returnsInputTokens`, `wrongCaller_reverts`. |
| Day 3 | Implement `autoReleaseStuckSwap()` — Scenario A. Test: `beforeDelay_reverts`, `afterDelay_releasesFloor`, `vaultGetsNothing`, `doubleRelease_reverts`. |
| Day 4 | Implement `cancelStuckAuction()` — Scenario B. Test: `beforeTimeout_reverts`, `afterTimeout_voidsTrade`. Implement `publishDecryptResult` sig verification using `ECDSA.recover` against immutable `COFHE_VERIFIER`. |
| Day 5 | Write `PublishDecryptResult.t.sol`: valid sig, invalid sig, replay attack. Full flow test: `decryptForTx` → `publishDecryptResult` → `enforceEncryptedMinimum` → `vault.recordSurplus`. `forge test` — all 65+ tests must pass. |

### Week 2 — Frontend Gaps + Deployment

| Day | Task |
|---|---|
| Day 1 | Create `fe/src/lib/errorHandling.js` with `CONTRACT_ERROR_MESSAGES` and `COFHE_ERROR_MESSAGES` maps. Wire `decodeError()` into all existing try-catch blocks in `GhostSwap.jsx`. |
| Day 2 | Create `fe/src/hooks/useCoFheHealth.js` (poll every 30s, expose status dot). Add green/amber/red health indicator to GhostSwap header. |
| Day 3 | Create `fe/src/hooks/useDecryptPoller.js` with staged timeout logic. Wire into `PENDING_REVEAL` state. Add `COPROCESSOR_DELAYED` and `STUCK_CANCELLABLE` UI states. |
| Day 4 | Wire `decryptForTx()` → `publishDecryptResult` into reveal flow in `GhostSwap.jsx`. Add cancel button UI (appears after 6h). Add auto-release claim button (appears after 24h). |
| Day 5 | Write `Deploy.s.sol` for Arbitrum Sepolia (no `chainId == 31337` check). Deploy hook + vault + periphery to Sepolia. Verify all on Arbiscan. End-to-end test: real encrypted swap on Sepolia, reveal, verify ciphertext in calldata. |

---

## 8. Security Assumptions

Document explicitly for audit application. Each item is a trust boundary.

| Assumption | Risk | Notes |
|---|---|---|
| CoFHE Coprocessor Integrity | `FHE.gte` result is trusted without independent onchain verification | Compromised coprocessor could allow fills below encrypted minimum |
| `publishDecryptResult` (pre-fix) | Currently accepts client-provided plaintext without CoFHE signature verification | **MUST be fixed before production.** After fix: accepts only CoFHE verifier ECDSA signature. |
| Solver Allowlist | Owner controls `registerSolver`/`unregisterSolver` | Compromised owner key = malicious solvers gain auction access. Recommend multi-sig ownership. |
| `amountIn` Not Encrypted | Sophisticated solvers can estimate encrypted floor from visible `amountIn` + typical slippage conventions | Protection is stronger for variable-slippage users (DAOs, whales) than retail with predictable 0.5% slippage. Known limitation, not a bug. |
| Auction Winner Binding | Periphery uses `msg.sender == auction.winner` | No EIP-712 relay envelopes yet. Winner must call `executeIntent` directly. Relay attacks possible if winner is exploitable contract. |
| CoFHE Availability | Protocol degrades gracefully via emergency fallback paths | **WITHOUT emergency functions implemented, a CoFHE outage can lock trader funds indefinitely. Build P0 items first.** |

---

## 9. Deployment Checklist — Arbitrum Sepolia

### Contracts

- [ ] `forge test` — all 65+ tests pass
- [ ] `Deploy.s.sol` runs against Arbitrum Sepolia without errors
- [ ] Hook address satisfies v4 hook permission bits
- [ ] GhostVault deployed with hook address as immutable
- [ ] GhostVaultPeriphery deployed with vault + hook addresses
- [ ] All contracts verified on Arbiscan
- [ ] Deployed addresses written to `deployments/arbitrum-sepolia.json`

### Frontend

- [ ] `fe/.env` has `VITE_CHAIN_ID=421614` and all contract addresses
- [ ] `@cofhe/sdk` initializes against `chains.arbitrumSepolia`
- [ ] `encryptMinOut()` produces real ciphertext (confirm via SDK step logs)
- [ ] Health check dot shows green on Sepolia
- [ ] Full swap flow works end-to-end on Sepolia
- [ ] Block countdown counts real Sepolia blocks
- [ ] Error messages appear correctly for invalid inputs

### Demo Verification

- [ ] Submit one real encrypted swap on Sepolia — capture txHash
- [ ] Verify on Arbiscan — calldata shows ciphertext not plaintext
- [ ] Call reveal after `decryptReadyBlock` — trade details visible to trader only
- [ ] Record 3-minute screen recording of full flow for Wave 5 submission

---

*GhostSwap — Built on Fhenix CoFHE + Uniswap v4 + Arbitrum Sepolia*
*Fhenix x AKINDO Private By Design Buildathon — Wave 4 to Wave 5*
*PRD Version 1.0 — May 2026*
*Privacy by math, not policy.*