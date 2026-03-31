# GhostSwap Frontend

GhostSwap is a Vite + React frontend for the Post Settle Reveal flow using the Uniswap v4 hook in this repository.

## Quick start

1. Install dependencies.

```bash
npm install
```

2. Create local env file.

```bash
cp .env.example .env
```

3. Fill values in `.env`.

Required values:
- `VITE_CHAIN_ID`
- `VITE_POST_SETTLE_HOOK`
- `VITE_POOL_TOKEN0`
- `VITE_POOL_TOKEN1`
- Token metadata addresses used in UI (`VITE_TOKEN_*`)

4. Start dev server.

```bash
npm run dev
```

## Build

```bash
npm run build
```

## Notes

- Local Anvil defaults are included for mock verifier contracts and swap router in `src/config/contracts.js`.
- The submit flow enforces token balance and router allowance checks before swap submission.
- Trade history is loaded from hook events and displayed with pagination.
