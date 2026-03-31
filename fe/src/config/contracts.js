const DEFAULT_LOCAL_CHAIN_ID = 31337;
const DEFAULT_SWAP_ROUTER = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9";
const DEFAULT_MOCK_ZK_VERIFIER = "0x0000000000000000000000000000000000000100";
const DEFAULT_MOCK_ZK_VERIFIER_SIGNER = "0x0000000000000000000000000000000000000101";

export const CONTRACTS = {
  postSettleRevealHook: import.meta.env.VITE_POST_SETTLE_HOOK || "",
  swapRouter: import.meta.env.VITE_SWAP_ROUTER || DEFAULT_SWAP_ROUTER,
  mockZkVerifier: import.meta.env.VITE_MOCK_ZK_VERIFIER || DEFAULT_MOCK_ZK_VERIFIER,
  mockZkVerifierSigner: import.meta.env.VITE_MOCK_ZK_VERIFIER_SIGNER || DEFAULT_MOCK_ZK_VERIFIER_SIGNER,
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
  return Number.isFinite(envChainId) && envChainId > 0 ? envChainId : DEFAULT_LOCAL_CHAIN_ID;
}

export function chainNameById(chainId) {
  if (chainId === 31337) return "ANVIL";
  if (chainId === 11155111) return "SEPOLIA";
  if (chainId === 421614) return "ARBITRUM SEPOLIA";
  if (chainId === 84532) return "BASE SEPOLIA";
  return `CHAIN ${chainId}`;
}
