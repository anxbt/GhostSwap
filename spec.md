# GhostSwap — Wave 5 Final Spec: Live Arbitrum Sepolia Deployment & Wiring

---

## 1. Goal

Take GhostSwap from a locally-mocked, Anvil-configured build to a **live, demonstrable deployment on
Arbitrum Sepolia (chainId 421614)** where a real encrypted swap runs end-to-end against the live
Fhenix CoFHE coprocessor, and where the emergency cancel / auto-release paths can be **executed live
on camera** for the Wave 5 submission video.

This is a **wiring + deployment** effort. The protocol contracts and tests are already complete.

---

## 2. Current State (ground truth, verified against the working tree)

| Area | State | Evidence |
|---|---|---|
| Emergency hook functions | ✅ Implemented | `cancelStuckSwap` (`PostSettleRevealHook.sol:653`), `autoReleaseStuckSwap` (`:677`), `cancelStuckAuction` (`:700`) |
| `publishDecryptResult` ECDSA | ✅ Real verification vs `COFHE_VERIFIER` | `PostSettleRevealHook.sol:518-529` |
| `EmergencyResolved` enum / `AuctionCancelled` / errors | ✅ Present | `IPostSettleReveal.sol:13, 45, 71-77` |
| Delay constants 1800/7200/300 | ✅ Present (compile-time `constant`) | `PostSettleRevealHook.sol:48-50` |
| Tests | ✅ 72 passing, `forge build` clean | 7 test files incl. `EmergencyIntegration.t.sol` (6 tests) |
| `Deploy.s.sol` | ⚠️ Deploys hook/vault/periphery + JSON, **no pool/tokens/router/liquidity** | `script/Deploy.s.sol:1-100` |
| FE error decode / poller / cancel+autorelease buttons | ✅ Wired | `errorHandling.js`, `useDecryptPoller.js`, `GhostSwap.jsx:1059-1097, 424-440` |
| FE `useCoFheHealth` | ⚠️ Called with `null` → dot always "offline" | `GhostSwap.jsx:472` |
| FE chain config | ❌ `.env` = Anvil 31337; `@cofhe/sdk` hardcoded to 421614 → encryption throws | `fe/.env`, `useCofhe.js:6,29-33` |
| Reveal flow | Legacy `revealSwapDetails` (kept by decision) | `GhostSwap.jsx:1051` |

**The PRD §4.2 "NOT BUILT" list is stale and must be ignored.**

---

## 3. Scope

**In scope**
- New self-contained Sepolia deploy script (tokens, routers, hook, vault, periphery, pool init, liquidity, `fe/.env`).
- Owner-settable emergency delays so cancel/auto-release execute live (Phase C).
- FE repointing to 421614 + health-dot client + poller reads real on-chain delays.
- End-to-end verification + demo runbook.

**Out of scope**
- New reveal flow (`decryptForTx` → `publishDecryptResult`). Legacy `revealSwapDetails` is kept.
- `cancelStuckAuction` UI (stays in ABI, unused).
- Gas benchmarks (PRD P2).
- Arbiscan source verification (optional, noted).

**Decisions locked**
- Target: Arbitrum Sepolia live.
- User has: funded deployer `PRIVATE_KEY` + `ARBITRUM_SEPOLIA_RPC`.
- `COFHE_VERIFIER_ADDRESS` = deployer (placeholder; `publishDecryptResult` is off the critical path).
- Cancel + auto-release **must execute live on camera**.

---

## 4. Architecture Recap (what runs where on Sepolia)

```
Browser (fe/)
  @cofhe/sdk encrypts amountOutMinimum  → InEuint128 {ctHash, signature}   [chain 421614 ONLY]
  EIP-712 sign intent → encode into hookData → PoolSwapTest.swap()
        │
        ▼
PostSettleRevealHook (deployed by us)              Canonical v4 PoolManager  0xFB3e…a317
  beforeSwap: verify EIP-712 + ZK proof via LIVE CoFHE verifier, store euint128
  afterSwap : queue FHE.gte, record settlement, set decryptReadyBlock
  reveal/emergency: revealSwapDetails | cancelStuckSwap | autoReleaseStuckSwap
        │
        ▼
GhostVault / GhostVaultPeriphery (deployed by us)  +  Live Fhenix CoFHE coprocessor (already on Sepolia)
```

We deploy: 2 MockERC20, PoolSwapTest, PoolModifyLiquidityTest, Hook, Vault, Periphery.
We reuse: canonical PoolManager, live CoFHE (TaskManager/verifier).

---

## 5. Work Items

### 5.1 Phase A — `script/DeploySepolia.s.sol` (NEW)

Self-contained, modeled on `99_LocalSetup.s.sol:120-191` but for 421614; **no CoFHE mocks**.

**Constructor/getters used:** hook ctor `(IPoolManager, uint256 revealDelayBlocks, address owner,
address cofheVerifier)` (`PostSettleRevealHook.sol:87`); `GhostVault(asset, hook)`;
`GhostVaultPeriphery(swapRouter, vault, hook, owner)`.

**Steps**
1. `require(block.chainid == 421614, "DeploySepolia: wrong chain");`
2. Env: `PRIVATE_KEY` (req), `ARBITRUM_SEPOLIA_RPC` (CLI), `REVEAL_DELAY_BLOCKS` (default 15),
   `HOOK_OWNER` (default deployer), `COFHE_VERIFIER_ADDRESS` (default deployer).
3. Resolve canonical PoolManager via `Constants` → `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317`.
4. Deploy `MockERC20 tokenA/tokenB` (18 dec), sort to `(token0, token1)`, `mint(deployer, 1_000_000 ether)` each.
5. Deploy `PoolSwapTest swapRouter` and `PoolModifyLiquidityTest lpRouter` against the manager.
   *(FE swap path requires the `PoolSwapTest` ABI — `swapAbis.js` `POOL_SWAP_TEST_ABI`.)*
6. Mine hook address (`HookMiner.find`, flags `BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG`), deploy hook with
   `CREATE2` salt, assert address match (reuse `Deploy.s.sol:42-56`).
7. Deploy `GhostVault(token1, hook)` and `GhostVaultPeriphery(swapRouter, vault, hook, owner)`.
8. Wire: `vault.setOperator(periphery)`, `hook.setSurplusVault(vault)`,
   `hook.setAuthorizedRevealer(deployer, true)`.
9. Pool: build `PoolKey{token0, token1, fee=3000, tickSpacing=60, hooks=hook}`,
   `manager.initialize(poolKey, STARTING_PRICE=79228162514264337593543950336)`; approve `lpRouter`;
   `lpRouter.modifyLiquidity(poolKey, full-range, liquidityDelta=100 ether, "")` (reuse `99_LocalSetup.s.sol:164-191`).
10. Write `deployments/arbitrum-sepolia.json` (reuse `Deploy.s.sol:84-98`).
11. Write `fe/.env` via a `_writeFrontendEnv` mirroring `99_LocalSetup.s.sol:193-227` but
    `VITE_CHAIN_ID=421614` and the deployed addresses (see §6).

> **Why not the stock `01/01a/02/03` scripts:** they read hardcoded addresses from `Config.sol`
> (manual editing), seed liquidity via `posm`/Permit2, and never deploy the `PoolSwapTest` router the
> FE needs. One consolidated script = one command, no manual edits, FE-compatible router, atomic env write.
> `Deploy.s.sol` is left intact as a bare-protocol deploy.

### 5.2 Phase B — Frontend repointing & health dot

- **`fe/.env`**: generated by Phase A. No code change; read via `src/config/contracts.js:4-17`.
- **Health dot**: replace `useCoFheHealth(null)` at `GhostSwap.jsx:472` with a connected client (build
  it once with the `useCofhe.js:35-53` pattern, or a minimal fetch probe to the CoFHE endpoint), so the
  footer dot at `GhostSwap.jsx:1422` reflects healthy/degraded/offline.
- **chainId guard**: confirm `useCofhe.js:29-33` passes once the app runs on 421614.

### 5.3 Phase C — Owner-settable delays (live emergency demo)

**C1 — `PostSettleRevealHook.sol:48-50`**: convert the three `constant`s to public **storage** with
identical SCREAMING_CASE names (ABI/getters unchanged), add an onlyOwner setter:
```solidity
uint256 public CANCEL_DELAY_BLOCKS = 1800;
uint256 public FALLBACK_DELAY_BLOCKS = 7200;
uint256 public AUCTION_TIMEOUT_BLOCKS = 300;

function setEmergencyDelays(uint256 cancel_, uint256 fallback_, uint256 auction_) external onlyOwner {
    CANCEL_DELAY_BLOCKS = cancel_;
    FALLBACK_DELAY_BLOCKS = fallback_;
    AUCTION_TIMEOUT_BLOCKS = auction_;
    emit EmergencyDelaysUpdated(cancel_, fallback_, auction_); // add event to interface
}
```
No constructor change → **zero ripple** to `Deploy.s.sol`, `99_LocalSetup.s.sol`,
`00_PostSettleReveal.s.sol`, test harnesses, or `EmergencyIntegration.t.sol`. Defaults equal the old
constants → 72 tests stay green. Internal arithmetic unchanged (now reads storage).

**C2 — `fe/src/hooks/useDecryptPoller.js:4-6`**: remove the hardcoded `1800/7200`; accept
`cancelDelayBlocks` / `fallbackDelayBlocks` as inputs. In `GhostSwap.jsx`, read them once via
`hook.CANCEL_DELAY_BLOCKS()` / `hook.FALLBACK_DELAY_BLOCKS()` and pass into `useDecryptPoller` so the
button cadence matches what the contract will accept.

**C3 — demo procedure**: owner `setEmergencyDelays(5, 10, 3)` → submit swap, do not reveal → ~5 blocks
→ Cancel executes; second swap, ~10 blocks → Auto-Release executes → reset `setEmergencyDelays(1800, 7200, 300)`.

---

## 6. Config / Env

**Deploy env (shell):**
```
PRIVATE_KEY=0x…                       # funded Arb Sepolia deployer (REQUIRED)
ARBITRUM_SEPOLIA_RPC=https://…        # RPC (REQUIRED, passed via --rpc-url)
REVEAL_DELAY_BLOCKS=15                 # optional
HOOK_OWNER=0x…                         # optional, defaults to deployer
COFHE_VERIFIER_ADDRESS=0x…             # optional, defaults to deployer (placeholder)
ETHERSCAN_API_KEY=…                    # optional, only for --verify
```

**`fe/.env` (written by the script):**
```
VITE_CHAIN_ID=421614
VITE_POST_SETTLE_HOOK=0x…
VITE_VAULT_ADDRESS=0x…
VITE_VAULT_PERIPHERY=0x…
VITE_SWAP_ROUTER=0x…           # PoolSwapTest
VITE_POOL_TOKEN0=0x…
VITE_POOL_TOKEN1=0x…
VITE_POOL_FEE=3000
VITE_POOL_TICK_SPACING=60
VITE_SWAP_TAKE_CLAIMS=false
VITE_SWAP_SETTLE_USING_BURN=false
VITE_TOKEN_ETH=0x…  VITE_TOKEN_ETH_DECIMALS=18
VITE_TOKEN_USDC=0x… VITE_TOKEN_USDC_DECIMALS=18
VITE_INTENT_DEADLINE_SECONDS=1200
```

**`deployments/arbitrum-sepolia.json`:** `{ hook, vault, periphery, poolManager, swapRouter,
cofheVerifier, token0, token1, revealDelayBlocks (uint), deployer, chain: "arbitrum-sepolia" }`.

---

## 7. Deployment Runbook

1. `forge build && forge test` → expect 72 passing.
2. Export the deploy env (§6). Ensure deployer has Arb Sepolia ETH.
3. `forge script script/DeploySepolia.s.sol:DeploySepoliaScript --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast`
   *(add `--verify --etherscan-api-key $ETHERSCAN_API_KEY` to verify on Arbiscan).*
4. Confirm `deployments/arbitrum-sepolia.json` and a 421614 `fe/.env` were written.
5. `cd fe && npm install && npm run dev`.
6. Connect wallet on Arbitrum Sepolia; verify the config-issues banner is clear and the health dot resolves.

---

## 8. Verification & Acceptance Criteria

| # | Check | Pass condition |
|---|---|---|
| 1 | Build/tests | `forge test` = 72 passing after Phase C edits |
| 2 | Deploy | Script completes; JSON + `fe/.env` written; hook address matches mined address |
| 3 | App boot | App loads on 421614, no missing-env banner, health dot non-grey |
| 4 | Encrypt | Submitting a swap produces real ciphertext (SDK step logs); chainId guard passes |
| 5 | On-chain swap | `PoolSwapTest.swap` succeeds; `afterSwap` sets `decryptReadyBlock`; tracked swapId recorded |
| 6 | Privacy proof | Arbiscan calldata shows ciphertext, **not** plaintext `amountOutMinimum`; capture txHash |
| 7 | Reveal | After `decryptReadyBlock`, `revealSwapDetails` succeeds; details visible to trader |
| 8 | Cancel (live) | After `setEmergencyDelays(5,10,3)` + ~5 blocks unrevealed, Cancel tx succeeds → `EmergencyResolved` |
| 9 | Auto-release (live) | ~10 blocks unrevealed, Auto-Release tx succeeds → `EmergencyResolved` |
| 10 | Error UX | Bad inputs surface decoded messages (no raw reverts) via `decodeError` |
| 11 | Reset | `setEmergencyDelays(1800,7200,300)` restores production delays |

---

## 9. Risks

- **Live FHE in `afterSwap` (highest).** Never exercised against the real coprocessor — only mocks.
  If SDK ciphertext / on-chain ZK verify disagree, the swap reverts. **The first live swap is the
  integration test.** Mitigation: a throwaway dry-run swap before recording; keep RPC + Arbiscan open.
- **Arbitrum `block.number` semantics.** L1-paced (~12s). Reveal 15 blocks ≈ 3 min; demo delays 5/10
  blocks ≈ 1–2 min. Confirm cadence on first run; adjust `setEmergencyDelays` if blocks advance oddly.
- **Liquidity sizing.** 100 ether full-range liquidity must be enough for the demo swap size; bump if a
  swap fails on liquidity. Tokens are freely minted to the deployer.
- **Owner-mutable delays.** New owner power (Phase C). Acceptable: owner is already trusted
  (`registerSolver`). Add a §Security row.

---

## 10. Security Note (append to PRD §8)

> **Emergency delay configurability** — `setEmergencyDelays` lets the owner change cancel/auto-release/
> auction windows. Recommend multi-sig ownership in production; for the buildathon demo the owner is the
> deployer. No new trust boundary beyond the existing solver-allowlist owner powers.

---

## 11. File Change Summary

| File | Action |
|---|---|
| `script/DeploySepolia.s.sol` | **NEW** — full-stack Sepolia deploy + `fe/.env` writer |
| `src/hooks/PostSettleRevealHook.sol` | 3 delay `constant`s → public storage (same names) + `setEmergencyDelays` + event |
| `src/interface/IPostSettleReveal.sol` | add `EmergencyDelaysUpdated` event (+ optional setter sig) |
| `fe/src/hooks/useDecryptPoller.js` | accept on-chain delays instead of hardcoded 1800/7200 |
| `fe/src/GhostSwap.jsx` | pass real client to `useCoFheHealth`; fetch + pass delays to poller |
| `fe/.env` | regenerated for 421614 (by the script) |
| `deployments/arbitrum-sepolia.json` | generated artifact |
| `spec.md` | this document |
