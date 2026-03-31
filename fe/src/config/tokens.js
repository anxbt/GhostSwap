export const TOKENS = [
  {
    symbol: "ETH",
    name: "Ethereum",
    icon: "⟠",
    address: import.meta.env.VITE_TOKEN_ETH || "",
    decimals: Number(import.meta.env.VITE_TOKEN_ETH_DECIMALS || 18),
  },
  {
    symbol: "USDC",
    name: "USD Coin",
    icon: "◎",
    address: import.meta.env.VITE_TOKEN_USDC || "",
    decimals: Number(import.meta.env.VITE_TOKEN_USDC_DECIMALS || 6),
  },
  {
    symbol: "WBTC",
    name: "Wrapped Bitcoin",
    icon: "₿",
    address: import.meta.env.VITE_TOKEN_WBTC || "",
    decimals: Number(import.meta.env.VITE_TOKEN_WBTC_DECIMALS || 8),
  },
  {
    symbol: "ARB",
    name: "Arbitrum",
    icon: "●",
    address: import.meta.env.VITE_TOKEN_ARB || "",
    decimals: Number(import.meta.env.VITE_TOKEN_ARB_DECIMALS || 18),
  },
];

export function findTokenByAddress(address) {
  if (!address) return null;
  return TOKENS.find((token) => token.address.toLowerCase() === String(address).toLowerCase()) || null;
}
