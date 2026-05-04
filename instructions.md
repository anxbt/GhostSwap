# GhostSwap — INSTRUCTIONS.md

> Internal developer reference. Architecture decisions, FHE patterns,
> coding standards, and integration context for contributors and auditors.

---

## 1. Overview

### Project Goal

GhostSwap is a private swap execution protocol built on Uniswap v4.
It encrypts `amountOutMinimum` — the trader's reservation price — before
it leaves the browser. Solvers receive a ciphertext and are forced to
fill at their honest best price instead of the trader's worst acceptable
price.

### Problem Statement

Every DEX swap broadcasts `amountOutMinimum` in plaintext. Solvers read
this value before filling an order and fill at the floor price, extracting
the surplus between honest execution and the visible minimum. This is
solver-side price extraction — distinct from public front-running.

Flashbots and private mempools solve mempool-level front-running.
They do not prevent the solver filling your order from reading your
reservation price. GhostSwap closes this gap using Fully Homomorphic
Encryption (FHE) — computation on ciphertext with no decryption required.

### Core FHE Functionality

| Operation | Where | What It Does |
|---|---|---|
| `FHE.asEuint128(InEuint128)` | `beforeSwap` | Converts client ciphertext to onchain encrypted type |
| `FHE.allowTransient(euint128, address)` | `beforeSwap` | Grants CoFHE coprocessor access to encrypted value |
| `FHE.gt(euint128, euint128)` | `afterSwap` (Wave 3) | Compares encrypted actual output vs encrypted minimum |
| `FHE.decrypt(euint128)` | `reveal()` | Async decrypt request to CoFHE coprocessor |
| `FHE.sealoutput(euint128, bytes)` | `reveal()` | Seals decrypted result to trader's public key only |

Remove FHE from this architecture and the privacy guarantee collapses.
FHE is load-bearing, not cosmetic.

---

## 2. Tech Stack

### Smart Contracts

| Technology | Version | Purpose |
|---|---|---|
| Solidity | 0.8.26 | Contract language |
| Foundry (forge) | stable | Compilation, testing, deployment |
| Anvil | stable | Local devnet |
| Uniswap v4-core | latest | PoolManager, hook interfaces |
| Uniswap v4-periphery | latest | BaseHook, position manager |
| `@fhenixprotocol/cofhe-contracts` | latest | FHE.sol — encrypted types and operations |
| `cofhe-mock-contracts` | latest | Local CoFHE simulation for testing |
| `cofhe-hardhat-plugin` | latest | Hardhat integration (used in test tasks) |

### Frontend

| Technology | Version | Purpose |
|---|---|---|
| React | 18+ | UI framework |
| Vite | 5+ | Build tool |
| Tailwind CSS | 3+ | Styling |
| Viem | 2+ | Ethereum client (required by new SDK) |
| `@cofhe/sdk` | latest | **New Fhenix client SDK** (replaces cofhejs) |
| Wagmi | 2+ | React hooks for Ethereum |

### Networks

| Network | Chain ID | Purpose |
|---|---|---|
| Anvil local | 31337 | Development and testing |
| Arbitrum Sepolia | 421614 | Testnet — CoFHE coprocessor deployed here |

---

## 3. SDK Migration — CRITICAL CONTEXT

> ⚠️ `cofhejs` has been **sunsetted**. The new SDK is `@cofhe/sdk`.
> Any code referencing `cofhejs` must be migrated before Wave 2 deployment.

### Why The SDK Changed

`@cofhe/sdk` replaces `cofhejs` with:
- **Explicit API** — no implicit initialization or auto-generated permits
- **Builder pattern** — chainable `.execute()` calls with overrides
- **`decryptForTx`** — new method for generating onchain decrypt signatures
- **Deferred key loading** — FHE keys fetched lazily on first encrypt call
- **Structured errors** — typed `CofheError` with error codes

### Installation

```bash
# Remove old SDK
npm uninstall cofhejs

# Install new SDK
npm install @cofhe/sdk
```

### Migration Reference

#### Initialization

```ts
// BEFORE (cofhejs) — DEPRECATED
import { cofhejs } from 'cofhejs/node';
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: signer,
  environment: 'TESTNET',
});

// AFTER (@cofhe/sdk) — USE THIS
import { createCofheConfig, createCofheClient } from '@cofhe/sdk/web';
import { chains } from '@cofhe/sdk/chains';

const config = createCofheConfig({
  supportedChains: [chains.arbitrumSepolia],
});
const client = createCofheClient(config);
await client.connect(publicClient, walletClient);
```

#### Encrypting Inputs

```ts
// BEFORE (cofhejs) — DEPRECATED
import { cofhejs, Encryptable } from 'cofhejs/node';
const result = await cofhejs.encrypt(
  [Encryptable.uint128(3100000000n)],
  (state) => console.log(state)
);
if (!result.success) throw result.error;
const [encMinOut] = result.data;

// AFTER (@cofhe/sdk) — USE THIS
import { Encryptable } from '@cofhe/sdk';
const [encMinOut] = await client
  .encryptInputs([Encryptable.uint128(3100000000n)])
  .onStep((step) => console.log(step))
  .execute();
```

#### Decrypting for UI (View)

```ts
// BEFORE (cofhejs) — DEPRECATED
import { cofhejs, FheTypes } from 'cofhejs/node';
const result = await cofhejs.unseal(sealedValue, FheTypes.Uint128);
if (!result.success) throw result.error;
console.log(result.data);

// AFTER (@cofhe/sdk) — USE THIS
import { FheTypes } from '@cofhe/sdk';
const value = await client
  .decryptForView(ctHash, FheTypes.Uint128)
  .execute();
```

#### Decrypting for Onchain Publishing (NEW — not in cofhejs)

```ts
// This pattern did not exist in cofhejs
// Use this for the reveal() flow where decrypt result goes back onchain
const { decryptedValue, signature } = await client
  .decryptForTx(ctHash)
  .withoutPermit()
  .execute();

await ghostSwapHook.publishDecryptResult(ctHash, decryptedValue, signature);
```

#### Permits

```ts
// BEFORE (cofhejs) — DEPRECATED
await cofhejs.createPermit({ type: 'self', issuer: wallet.address });

// AFTER (@cofhe/sdk) — USE THIS
const permit = await client.permits.getOrCreateSelfPermit();
// Active permit is used automatically by decryptForView
```

#### Error Handling

```ts
// BEFORE (cofhejs) — DEPRECATED
if (!result.success) console.error(result.error); // string

// AFTER (@cofhe/sdk) — USE THIS
import { isCofheError } from '@cofhe/sdk';
try {
  const encrypted = await client
    .encryptInputs([Encryptable.uint128(3100000000n)])
    .execute();
} catch (err) {
  if (isCofheError(err)) {
    console.error(err.code);    // CofheErrorCode enum
    console.error(err.message);
  }
}
```

#### Type Renames

| Old (`cofhejs`) | New (`@cofhe/sdk`) |
|---|---|
| `CoFheInUint128` | `EncryptedUint128Input` |
| `CoFheInUint64` | `EncryptedUint64Input` |
| `CoFheInUint32` | `EncryptedUint32Input` |
| `CoFheInBool` | `EncryptedBoolInput` |
| `CoFheInAddress` | `EncryptedAddressInput` |

#### Import Path Changes

| Old (`cofhejs`) | New (`@cofhe/sdk`) |
|---|---|
| `cofhejs/node` | `@cofhe/sdk/node` |
| `cofhejs/web` | `@cofhe/sdk/web` |
| (not available) | `@cofhe/sdk/chains` |
| (not available) | `@cofhe/sdk/permits` |
| (not available) | `@cofhe/sdk/adapters` |

---

## 4. Project Structure

```
ghostswap/
├── src/
│   ├── PostSettleRevealHook.sol      # Core hook — beforeSwap, afterSwap, reveal
│   ├── interfaces/
│   │   └── IGhostSwap.sol            # External interface definition
│   └── libraries/
│       └── IntentLib.sol             # SwapIntent struct, encoding helpers
│
├── test/
│   ├── PostSettleRevealHook.t.sol    # Unit tests — happy path + guards
│   └── PostSettleRevealHook.integration.t.sol  # Full lifecycle tests
│
├── script/
│   ├── 99_LocalSetup.s.sol           # Anvil devnet deployment + mock CoFHE
│   └── Deploy.s.sol                  # Arbitrum Sepolia deployment
│
├── frontend/
│   ├── src/
│   │   ├── App.jsx                   # Router — landing ↔ swap
│   │   ├── LandingPage.jsx           # Hero, problem statement, how it works
│   │   ├── GhostSwap.jsx             # Swap interface — all 6 states
│   │   ├── config/
│   │   │   └── tokens.js             # Static token list (Wave 1)
│   │   └── hooks/
│   │       └── useCofhe.js           # @cofhe/sdk wrapper — encrypt + reveal
│   ├── package.json
│   └── vite.config.js
│
├── foundry.toml                      # Foundry config — solc 0.8.26, cancun EVM
├── remappings.txt                    # Import remappings for v4-core, v4-periphery
└── INSTRUCTIONS.md                   # This file
```

### Key Files Explained

**`PostSettleRevealHook.sol`** — The core contract. Extends `BaseHook`.
Registers `beforeSwap` and `afterSwap` permissions. Stores encrypted
intent in `beforeSwap`, records settlement in `afterSwap`, enforces
block delay and caller auth in `reveal()`.

**`99_LocalSetup.s.sol`** — Deploys mock CoFHE contracts (MockTaskManager,
MockZkVerifier, ACL) alongside the hook for local Anvil testing. This
script is devnet-only. Never run against testnet or mainnet.

**`useCofhe.js`** — Frontend wrapper around `@cofhe/sdk`. Handles
client initialization, encryption of `amountOutMinimum`, permit creation,
and decryption after reveal. All SDK interactions go through this hook.

---

## 5. FHE Patterns

### Pattern 1 — Encrypt Before Send

Client encrypts `amountOutMinimum` before the transaction is submitted.
The contract never sees the plaintext.

```ts
// frontend/src/hooks/useCofhe.js
import { createCofheConfig, createCofheClient } from '@cofhe/sdk/web';
import { chains } from '@cofhe/sdk/chains';
import { Encryptable } from '@cofhe/sdk';

export async function encryptMinOut(minOutRaw: bigint, publicClient, walletClient) {
  const config = createCofheConfig({
    supportedChains: [chains.arbitrumSepolia],
  });
  const client = createCofheClient(config);
  await client.connect(publicClient, walletClient);

  const [encMinOut] = await client
    .encryptInputs([Encryptable.uint128(minOutRaw)])
    .execute();

  return encMinOut; // EncryptedUint128Input — pass as hookData
}
```

### Pattern 2 — Store Encrypted Onchain

```solidity
// In beforeSwap
function beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {

    if (hookData.length > 0) {
        // Decode the encrypted input from client
        InEuint128 memory encMinOut = abi.decode(hookData, (InEuint128));

        // Convert to onchain encrypted type
        euint128 storedMinOut = FHE.asEuint128(encMinOut);

        // Grant access — hook can read, CoFHE coprocessor can process
        FHE.allowTransient(storedMinOut, address(this));

        // Store with intent
        bytes32 intentId = keccak256(abi.encodePacked(sender, block.number));
        intents[intentId].amountOutMinimum = storedMinOut;
        intents[intentId].state = SwapState.IntentCaptured;
    }

    return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
}
```

### Pattern 3 — Async Decrypt with Permit

The CoFHE coprocessor decryption is not synchronous. The result is not
available in the same transaction. Design all reveal flows assuming async.

```solidity
// reveal() initiates decrypt — result comes back via callback
function reveal(bytes32 intentId) external {
    SwapIntent storage intent = intents[intentId];

    require(intent.trader == msg.sender, "Not your trade");
    require(intent.state == SwapState.SettledPendingReveal, "Wrong state");
    require(block.number >= intent.decryptReadyBlock, "Too early");

    intent.state = SwapState.Revealed;

    // Async decrypt — CoFHE coprocessor processes this
    // Result returned to trader via sealoutput / publishDecryptResult
    FHE.decrypt(intent.amountOutMinimum);
}
```

```ts
// Frontend — after reveal() tx confirms, decrypt for view
const value = await client
  .decryptForView(ctHash, FheTypes.Uint128)
  .execute();

// Or for onchain publishing (Wave 3 enforcement)
const { decryptedValue, signature } = await client
  .decryptForTx(ctHash)
  .withoutPermit()
  .execute();
```

### Pattern 4 — FHE Comparison (Wave 3)

```solidity
// afterSwap — enforce encrypted minimum
// This pattern requires the decrypt result to be available
// Uses decryptForTx flow from client
function enforceMinimum(
    bytes32 intentId,
    uint128 decryptedValue,
    bytes memory signature
) external {
    SwapIntent storage intent = intents[intentId];

    // Publish the decrypt result onchain with CoFHE signature
    FHE.publishDecryptResult(
        intent.amountOutMinimum,
        decryptedValue,
        signature
    );

    // Now compare plaintext values
    require(
        uint128(intent.actualAmountOut) >= decryptedValue,
        "Fill below encrypted minimum"
    );
}
```

### Block Delay — Why 15 Blocks

The reveal delay of 15 blocks (~30 seconds on Arbitrum) is the CoFHE
finality window. The coprocessor needs sufficient block confirmations
before the decrypt result is considered final. This value is configurable
via `REVEAL_DELAY` constant. Do not set below 11 blocks on Arbitrum
Sepolia — this risks decrypt result unavailability at reveal time.

---

## 6. Coding Standards

### Solidity

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Import order: std lib → external → internal
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {FHE, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {IntentLib} from "./libraries/IntentLib.sol";
```

- Named imports only — no `import "..."` without braces
- State variables: `private` by default, explicit getter if needed
- Events for every state transition — judges and indexers read these
- `onlyPoolManager` modifier on all hook callbacks
- No `tx.origin` usage anywhere
- Reentrancy: no external calls in `reveal()` — only storage + events

### Naming

| Type | Convention | Example |
|---|---|---|
| Contract | PascalCase | `PostSettleRevealHook` |
| Function | camelCase | `beforeSwap`, `revealSwapDetails` |
| State variable | camelCase | `settledAtBlock` |
| Constant | UPPER_SNAKE | `REVEAL_DELAY` |
| Event | PascalCase | `IntentCaptured`, `TradeRevealed` |
| Error | PascalCase | `NotYourTrade`, `TooEarlyToReveal` |
| Mapping key | descriptive | `intentsByTrader`, `nonceUsed` |

### Custom Errors Over Require Strings

```solidity
// DO THIS
error NotYourTrade(address caller, address trader);
error TooEarlyToReveal(uint256 currentBlock, uint256 readyBlock);
error IntentAlreadyRevealed(bytes32 intentId);

// NOT THIS
require(intent.trader == msg.sender, "Not your trade");
```

### TypeScript / Frontend

- `@cofhe/sdk` only — never import from `cofhejs`
- All SDK calls wrapped in try/catch with `isCofheError` check
- No hardcoded private keys anywhere — use environment variables
- Token list from `config/tokens.js` — never hardcoded in components
- All FHE operations isolated in `hooks/useCofhe.js`

### Foundry Testing

```bash
# Run all tests
forge test -vv

# Run specific contract
forge test --match-contract PostSettleRevealHook -vv

# Run with gas report
forge test --gas-report

# Fork test against Arbitrum Sepolia
forge test --fork-url $ARBITRUM_SEPOLIA_RPC -vv
```

Always test:
- Happy path end-to-end
- Reveal before block threshold (must revert)
- Wrong caller reveal (must revert)
- Double reveal (must revert)
- State transition guards

---

## 7. User Stories

### Trader — Private Swap

```
As a trader,
I want to submit a swap where my minimum acceptable price is encrypted,
So that the solver cannot fill me at my worst acceptable price.

Acceptance criteria:
- amountOutMinimum is encrypted client-side before tx submission
- Transaction calldata contains ciphertext, not plaintext
- Swap executes correctly despite encrypted minimum
- After 15 blocks, I can call reveal() and see my result
- Nobody else can decrypt my result
```

### Trader — Reveal Result

```
As a trader,
I want to decrypt my trade result after settlement,
So that I can verify what I received and calculate surplus captured.

Acceptance criteria:
- Reveal button is disabled before block threshold
- Reveal button enables exactly at decryptReadyBlock
- After reveal, I see: amountIn, amountOut, execution price, surplus
- Reveal is one-time — duplicate calls are rejected
```

### Compliance Party — Permissioned View (Wave 2)

```
As a compliance officer at an institution,
I want to be able to view trade details for our organization's swaps,
So that I can satisfy audit requirements without the trade being public.

Acceptance criteria:
- Trader can grant reveal permission to a specific address
- Compliance address can call reveal() with their permit
- No other address can access the trade details
- All access grants are emitted as events for audit trail
```

### DAO Treasury Manager — Large Order (Wave 4)

```
As a DAO treasury manager,
I want to execute a large sell order over multiple blocks,
With each sub-order's minimum price encrypted,
So that solvers cannot extract value from any individual fill.

Acceptance criteria:
- Vault accepts deposit of token to be sold
- Vault executes sub-orders on a configurable schedule
- Each sub-order uses encrypted amountOutMinimum
- Surplus from all sub-orders accumulates in vault
- Vault distributes surplus proportionally to depositors
```

---

## 8. APIs and Integrations

### Fhenix CoFHE Coprocessor

**What it is:** Off-chain coprocessor that executes FHE operations and
returns encrypted results. Deployed on Arbitrum Sepolia.

**How it connects:** Solidity contracts emit events requesting FHE
computation. The coprocessor detects these events, processes them, and
submits results back onchain. This is async — results are not available
in the same block as the request.

**Local mock:** `cofhe-mock-contracts` simulates this for Anvil devnet.
Mock contracts handle the same interface but return results synchronously
for testing purposes. Gas costs are higher in mock mode.

**Endpoints:**
- Arbitrum Sepolia coprocessor: configured automatically via `@cofhe/sdk`
  when `chains.arbitrumSepolia` is passed to `createCofheConfig`
- No manual RPC configuration needed — SDK handles coprocessor discovery

### Uniswap v4 PoolManager

**What it is:** Singleton contract managing all v4 pools. Calls hook
callbacks at defined lifecycle points.

**How it connects:** Hook is registered at pool creation by passing hook
address in `PoolKey`. PoolManager calls `beforeSwap` and `afterSwap`
on every swap. Hook must return correct selectors.

**Key constraint:** Only one hook per pool. Cannot combine GhostSwap hook
with another hook on the same pool — merge logic into one contract.

**Deployed addresses:**
- Arbitrum Sepolia: `0x...` (see `script/Deploy.s.sol`)
- Anvil local: deployed by `99_LocalSetup.s.sol`

### @cofhe/sdk (Client SDK)

**What it is:** JavaScript/TypeScript library for client-side FHE
operations. Handles encryption, permits, and decryption.

**Requires:** Viem 2+, Node.js 18+, TypeScript 5+

**Initialization pattern:**
```ts
import { createCofheConfig, createCofheClient } from '@cofhe/sdk/web';
import { chains } from '@cofhe/sdk/chains';

const config = createCofheConfig({
  supportedChains: [chains.arbitrumSepolia],
});
const client = createCofheClient(config);
await client.connect(publicClient, walletClient);
```

**Key methods:**
- `client.encryptInputs([...]).execute()` — encrypt before sending
- `client.decryptForView(ctHash, type).execute()` — decrypt for UI
- `client.decryptForTx(ctHash).execute()` — decrypt + get onchain signature
- `client.permits.getOrCreateSelfPermit()` — manage access permits

### Arbiscan (Arbitrum Sepolia Explorer)

Used for contract verification and judge review of deployed contracts.

```bash
# Verify after deployment
forge verify-contract \
  --chain arbitrum-sepolia \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  $CONTRACT_ADDRESS \
  src/PostSettleRevealHook.sol:PostSettleRevealHook
```

---

## 9. Environment Variables

```bash
# .env — never commit this file

# Deployment
PRIVATE_KEY=0x...                          # Deployer wallet private key

# Networks
ARBITRUM_SEPOLIA_RPC=https://...           # Arbitrum Sepolia RPC URL

# Verification
ETHERSCAN_API_KEY=...                      # Arbiscan API key

# Frontend (Vite — prefix with VITE_)
VITE_HOOK_ADDRESS=0x...                    # Deployed hook contract address
VITE_CHAIN_ID=421614                       # 421614 = Arbitrum Sepolia
```

---

## 10. Known Issues and Wave Targets

| Issue | Severity | Wave |
|---|---|---|
| Router identity: `msg.sender` is router not user | High | Wave 2 |
| Client encryption uses mock mode | High | Wave 2 |
| `encryptedMinOut` stored but not enforced | High | Wave 3 |
| No async decrypt callback handling | High | Wave 3 |
| `DecryptReady` state is a no-op | Medium | Wave 3 |
| No compliance address reveal | Medium | Wave 2 |
| No emergency timelock fallback | Medium | Wave 3 |
| Token list is static config | Low | Wave 4+ |

---

*GhostSwap — Privacy by math, not policy.*
*Fhenix × AKINDO Private By Design dApp Buildathon · 2026*