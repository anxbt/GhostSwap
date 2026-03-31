export function shortAddress(address) {
  if (!address || typeof address !== "string") return "";
  if (address.length < 10) return address;
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

export function toNumberSafe(value, fallback = 0) {
  try {
    return Number(value);
  } catch {
    return fallback;
  }
}
