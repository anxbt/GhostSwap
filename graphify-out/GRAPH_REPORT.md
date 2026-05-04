# Graph Report - /Users/rishav/Desktop/GhostSwap  (2026-04-29)

## Corpus Check
- 14 files · ~20,242 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 45 nodes · 45 edges · 15 communities detected
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 4 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

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

## God Nodes (most connected - your core abstractions)
1. `toStorageKey()` - 4 edges
2. `toTrackedSwapStorageKey()` - 4 edges
3. `getTrackedSwapIds()` - 4 edges
4. `setTrackedSwapIds()` - 4 edges
5. `GhostSwap()` - 4 edges
6. `normalizeSwapIds()` - 3 edges
7. `addTrackedSwapId()` - 3 edges
8. `getStoredHookNonce()` - 2 edges
9. `setStoredHookNonce()` - 2 edges
10. `mapSubmitError()` - 2 edges

## Surprising Connections (you probably didn't know these)
- `mapSubmitError()` --calls--> `mapCofheError()`  [INFERRED]
  /Users/rishav/Desktop/GhostSwap/fe/src/GhostSwap.jsx → /Users/rishav/Desktop/GhostSwap/fe/src/hooks/useCofhe.js
- `GhostSwap()` --calls--> `getExpectedChainId()`  [INFERRED]
  /Users/rishav/Desktop/GhostSwap/fe/src/GhostSwap.jsx → /Users/rishav/Desktop/GhostSwap/fe/src/config/contracts.js
- `GhostSwap()` --calls--> `shortAddress()`  [INFERRED]
  /Users/rishav/Desktop/GhostSwap/fe/src/GhostSwap.jsx → /Users/rishav/Desktop/GhostSwap/fe/src/lib/format.js
- `GhostSwap()` --calls--> `chainNameById()`  [INFERRED]
  /Users/rishav/Desktop/GhostSwap/fe/src/GhostSwap.jsx → /Users/rishav/Desktop/GhostSwap/fe/src/config/contracts.js

## Communities

### Community 0 - "Community 0"
Cohesion: 0.2
Nodes (0): 

### Community 1 - "Community 1"
Cohesion: 0.33
Nodes (4): chainNameById(), getExpectedChainId(), shortAddress(), GhostSwap()

### Community 2 - "Community 2"
Cohesion: 0.4
Nodes (0): 

### Community 3 - "Community 3"
Cohesion: 0.6
Nodes (5): addTrackedSwapId(), getTrackedSwapIds(), normalizeSwapIds(), setTrackedSwapIds(), toTrackedSwapStorageKey()

### Community 4 - "Community 4"
Cohesion: 0.5
Nodes (4): mapSubmitError(), encryptMinOut(), mapCofheError(), normalizeEncryptedInput()

### Community 5 - "Community 5"
Cohesion: 0.67
Nodes (3): getStoredHookNonce(), setStoredHookNonce(), toStorageKey()

### Community 6 - "Community 6"
Cohesion: 1.0
Nodes (0): 

### Community 7 - "Community 7"
Cohesion: 1.0
Nodes (0): 

### Community 8 - "Community 8"
Cohesion: 1.0
Nodes (0): 

### Community 9 - "Community 9"
Cohesion: 1.0
Nodes (0): 

### Community 10 - "Community 10"
Cohesion: 1.0
Nodes (0): 

### Community 11 - "Community 11"
Cohesion: 1.0
Nodes (0): 

### Community 12 - "Community 12"
Cohesion: 1.0
Nodes (0): 

### Community 13 - "Community 13"
Cohesion: 1.0
Nodes (0): 

### Community 14 - "Community 14"
Cohesion: 1.0
Nodes (0): 

## Knowledge Gaps
- **Thin community `Community 6`** (2 nodes): `App()`, `App.jsx`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 7`** (1 nodes): `hardhat.config.ts`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 8`** (1 nodes): `tailwind.config.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 9`** (1 nodes): `vite.config.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 10`** (1 nodes): `eslint.config.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 11`** (1 nodes): `postcss.config.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 12`** (1 nodes): `main.jsx`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 13`** (1 nodes): `postSettleRevealAbi.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 14`** (1 nodes): `swapAbis.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `GhostSwap()` connect `Community 1` to `Community 0`?**
  _High betweenness centrality (0.156) - this node is a cross-community bridge._
- **Why does `mapSubmitError()` connect `Community 4` to `Community 0`?**
  _High betweenness centrality (0.106) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `GhostSwap()` (e.g. with `getExpectedChainId()` and `shortAddress()`) actually correct?**
  _`GhostSwap()` has 3 INFERRED edges - model-reasoned connections that need verification._