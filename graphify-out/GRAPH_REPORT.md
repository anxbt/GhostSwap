# Graph Report - GhostSwap  (2026-05-09)

## Corpus Check
- 21 files · ~27,600 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 256 nodes · 266 edges · 35 communities (33 shown, 2 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 4 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4dcd978e`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]

## God Nodes (most connected - your core abstractions)
1. `**🚨 AI Common Decryption Errors**` - 20 edges
2. `👻 GhostSwap` - 14 edges
3. `GhostSwap — INSTRUCTIONS.md` - 11 edges
4. `🔓 Decryption Methods` - 10 edges
5. `Migration Reference` - 9 edges
6. `FHE Library Reference 📚` - 8 edges
7. `5. FHE Patterns` - 6 edges
8. `6. Coding Standards` - 6 edges
9. `FHE AI Assistant 🔐` - 6 edges
10. `toStorageKey()` - 5 edges

## Surprising Connections (you probably didn't know these)
- `mapSubmitError()` --calls--> `mapCofheError()`  [INFERRED]
  fe/src/GhostSwap.jsx → fe/src/hooks/useCofhe.js
- `GhostSwap()` --calls--> `getExpectedChainId()`  [INFERRED]
  fe/src/GhostSwap.jsx → fe/src/config/contracts.js
- `GhostSwap()` --calls--> `shortAddress()`  [INFERRED]
  fe/src/GhostSwap.jsx → fe/src/lib/format.js
- `GhostSwap()` --calls--> `chainNameById()`  [INFERRED]
  fe/src/GhostSwap.jsx → fe/src/config/contracts.js

## Communities (35 total, 2 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.07
Nodes (29): code:block1 (Example — standard Uniswap swap:), code:mermaid (graph TB), code:mermaid (graph TD), code:mermaid (graph LR), code:mermaid (stateDiagram-v2), code:mermaid (gantt), code:bash (# Clone), code:bash (PRIVATE_KEY=) (+21 more)

### Community 1 - "Community 1"
Cohesion: 0.09
Nodes (22): 10. Known Issues and Wave Targets, 1. Overview, 2. Tech Stack, 4. Project Structure, 8. APIs and Integrations, 9. Environment Variables, Arbiscan (Arbitrum Sepolia Explorer), code:ts (import { createCofheConfig, createCofheClient } from '@cofhe) (+14 more)

### Community 2 - "Community 2"
Cohesion: 0.09
Nodes (22): ➕ Arithmetic Operations, **Basic Arithmetic**, **Bitwise Operations (all euint types)**, **Boolean Logic (ebool only)**, code:solidity (import "@fhenixprotocol/cofhe-contracts/FHE.sol";), code:solidity (function eq(euint32 lhs, euint32 rhs) internal returns (eboo), code:solidity (function checkSufficientBalance(euint32 balance, euint32 amo), code:solidity (function and(ebool lhs, ebool rhs) internal returns (ebool)) (+14 more)

### Community 3 - "Community 3"
Cohesion: 0.24
Nodes (18): addTrackedSwapId(), computePoolId(), getSqrtPriceLimitX96(), getStoredHookNonce(), getTrackedSwapIds(), mapSubmitError(), MempoolComparison(), Noise() (+10 more)

### Community 4 - "Community 4"
Cohesion: 0.1
Nodes (20): **🚨 AI Common Decryption Errors**, code:block25, code:block26, code:block27, code:block28, code:block29, code:block30, code:block31 (+12 more)

### Community 5 - "Community 5"
Cohesion: 0.11
Nodes (19): 3. SDK Migration — CRITICAL CONTEXT, code:bash (# Remove old SDK), code:ts (// BEFORE (cofhejs) — DEPRECATED), code:ts (// BEFORE (cofhejs) — DEPRECATED), code:ts (// BEFORE (cofhejs) — DEPRECATED), code:ts (// This pattern did not exist in cofhejs), code:ts (// BEFORE (cofhejs) — DEPRECATED), code:ts (// BEFORE (cofhejs) — DEPRECATED) (+11 more)

### Community 6 - "Community 6"
Cohesion: 0.11
Nodes (19): **🔄 AI Common Decryption Patterns**, **AI Decryption Workflow Examples**, **🚨 AI Prerequisites for Decryption**, **📋 AI Transaction Flow**, code:solidity (// Available for all encrypted types), code:solidity (function requestDecryption(euint32 encryptedValue) external ), code:solidity (// Returns plaintext values), code:solidity (function useDecryptedValue(euint32 encryptedValue) external ) (+11 more)

### Community 7 - "Community 7"
Cohesion: 0.17
Nodes (11): AI Platforms, code:block1 (Load this comprehensive reference into any AI:), code:bash (claude "Read the fhe-assistant/core.md file and help me buil), code:block3 (📚 core.md    → Comprehensive FHE library reference (EVERYTHI), 🤝 Community Resources, Essential File, FHE AI Assistant 🔐, 🔑 Key Success Formula (+3 more)

### Community 8 - "Community 8"
Cohesion: 0.18
Nodes (11): 5. FHE Patterns, Block Delay — Why 15 Blocks, code:solidity (// In beforeSwap), code:solidity (// reveal() initiates decrypt — result comes back via callba), code:ts (// Frontend — after reveal() tx confirms, decrypt for view), code:solidity (// afterSwap — enforce encrypted minimum), code:ts (// frontend/src/hooks/useCofhe.js), Pattern 1 — Encrypt Before Send (+3 more)

### Community 9 - "Community 9"
Cohesion: 0.31
Nodes (5): chainNameById(), getExpectedChainId(), shortAddress(), toNumberSafe(), GhostSwap()

### Community 10 - "Community 10"
Cohesion: 0.22
Nodes (9): 6. Coding Standards, code:solidity (// SPDX-License-Identifier: MIT), code:solidity (// DO THIS), code:bash (# Run all tests), Custom Errors Over Require Strings, Foundry Testing, Naming, Solidity (+1 more)

### Community 11 - "Community 11"
Cohesion: 0.22
Nodes (9): 7. User Stories, code:block17 (As a trader,), code:block18 (As a trader,), code:block19 (As a compliance officer at an institution,), code:block20 (As a DAO treasury manager,), Compliance Party — Permissioned View (Wave 2), DAO Treasury Manager — Large Order (Wave 4), Trader — Private Swap (+1 more)

### Community 12 - "Community 12"
Cohesion: 0.22
Nodes (8): Build, code:bash (npm install), code:bash (cp .env.example .env), code:bash (npm run dev), code:bash (npm run build), GhostSwap Frontend, Notes, Quick start

### Community 13 - "Community 13"
Cohesion: 0.29
Nodes (7): **Between Encrypted Types (Casting)**, code:solidity (// From plaintext values), code:solidity (// Convert plaintext to encrypted), code:solidity (// From ebool to other types), code:solidity (// Convert encrypted bool to encrypted uint for arithmetic), **From Plaintext to Encrypted**, 🔧 Type Conversion Functions

### Community 14 - "Community 14"
Cohesion: 0.53
Nodes (4): LandingPage(), MempoolRow(), Redacted(), Reveal()

### Community 15 - "Community 15"
Cohesion: 0.7
Nodes (3): encryptMinOut(), mapCofheError(), normalizeEncryptedInput()

### Community 16 - "Community 16"
Cohesion: 0.5
Nodes (3): GhostSwap FHE Mock Integration Notes, Questions For Maintainers, Summary

## Knowledge Gaps
- **118 isolated node(s):** `What GhostSwap Actually Is`, `code:block1 (Example — standard Uniswap swap:)`, `code:mermaid (graph TB)`, `Why This Is Defensible`, `code:mermaid (graph TD)` (+113 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `GhostSwap — INSTRUCTIONS.md` connect `Community 1` to `Community 8`, `Community 10`, `Community 11`, `Community 5`?**
  _High betweenness centrality (0.064) - this node is a cross-community bridge._
- **Why does `🔓 Decryption Methods` connect `Community 6` to `Community 2`, `Community 4`?**
  _High betweenness centrality (0.051) - this node is a cross-community bridge._
- **Why does `FHE Library Reference 📚` connect `Community 2` to `Community 13`, `Community 6`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **What connects `What GhostSwap Actually Is`, `code:block1 (Example — standard Uniswap swap:)`, `code:mermaid (graph TB)` to the rest of the system?**
  _118 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.07 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._