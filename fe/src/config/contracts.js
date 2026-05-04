const DEFAULT_CHAIN_ID = 421614;
const DEFAULT_SWAP_ROUTER = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9";

export const CONTRACTS = {
  postSettleRevealHook: import.meta.env.VITE_POST_SETTLE_HOOK || "",
  vault: import.meta.env.VITE_VAULT_ADDRESS || "",
  vaultPeriphery: import.meta.env.VITE_VAULT_PERIPHERY || "",
  swapRouter: import.meta.env.VITE_SWAP_ROUTER || DEFAULT_SWAP_ROUTER,
};

export const POOL_CONFIG = {
  token0: import.meta.env.VITE_POOL_TOKEN0 || "",
  token1: import.meta.env.VITE_POOL_TOKEN1 || "",
  fee: Number(import.meta.env.VITE_POOL_FEE || 3000),
  tickSpacing: Number(import.meta.env.VITE_POOL_TICK_SPACING || 60),
  takeClaims: String(import.meta.env.VITE_SWAP_TAKE_CLAIMS || "false") === "true",
  settleUsingBurn: String(import.meta.env.VITE_SWAP_SETTLE_USING_BURN || "false") === "true",
};

export function getExpectedChainId() {
  const envChainId = Number(import.meta.env.VITE_CHAIN_ID);
  return Number.isFinite(envChainId) && envChainId > 0 ? envChainId : DEFAULT_CHAIN_ID;
}

export function chainNameById(chainId) {
  if (chainId === 31337) return "ANVIL";
  if (chainId === 11155111) return "SEPOLIA";
  if (chainId === 421614) return "ARBITRUM SEPOLIA";
  if (chainId === 84532) return "BASE SEPOLIA";
  return `CHAIN ${chainId}`;
}
