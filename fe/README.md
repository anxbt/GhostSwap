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
- `VITE_VAULT_ADDRESS`
- `VITE_VAULT_PERIPHERY`
- `VITE_SWAP_ROUTER`
- `VITE_POOL_TOKEN0`
- `VITE_POOL_TOKEN1`
- Token metadata addresses used in UI (`VITE_TOKEN_*`)
- Optional: `VITE_INTENT_DEADLINE_SECONDS` (default `1200`)

4. Start dev server.

```bash
npm run dev
```

## Build

```bash
npm run build
```

## Notes

- Wave 2 uses `@cofhe/sdk` for browser-side encryption and EIP-712 signed intent payloads.
- `@cofhe/sdk` encryption is configured for Arbitrum Sepolia (`421614`).
- The submit flow enforces token balance and router allowance checks before swap submission.
- Trade history is loaded from hook events and displayed with pagination.
