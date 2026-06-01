/**
 * Maps contract custom errors and CoFHE errors to user-facing messages.
 */

import { Interface } from "ethers";
import { POST_SETTLE_REVEAL_ABI } from "./postSettleRevealAbi";

// Extra fragments: ERC-7751 WrappedError (used by the CoFHE TaskManager to bubble up
// nested reverts) + the CoFHE coprocessor's own custom errors. With these, a wrapped
// on-chain revert decodes down to its true inner cause.
const EXTRA_ERROR_FRAGMENTS = [
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
  "error InvalidEncryptedInput(uint8 got, uint8 expected)",
  "error SecurityZoneOutOfBounds(int32 value)",
  "error InvalidHexCharacter(bytes1 char)",
  "error FailedCall()",
];

// Interface that knows the hook's custom errors + the CoFHE/wrapper errors, so we can
// decode reverts that bubble up through the swap router (whose ABI doesn't declare them).
const ERR_INTERFACE = new Interface([...POST_SETTLE_REVEAL_ABI, ...EXTRA_ERROR_FRAGMENTS]);

// Pull the raw revert data (0x + 4-byte selector + args) out of the many shapes
// ethers/RPC providers wrap it in.
export function extractRevertData(error) {
  const candidates = [
    error?.data,
    error?.info?.error?.data,
    error?.error?.data,
    error?.error?.error?.data,
    error?.cause?.data,
    error?.revert?.data,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.startsWith("0x") && c.length >= 10) return c;
    if (c && typeof c === "object" && typeof c.data === "string" && c.data.startsWith("0x")) return c.data;
  }
  return null;
}

// Recursively decode revert bytes, unwrapping ERC-7751 WrappedError to reach the real cause.
// Returns { name, args } for a known error, or { selector } for an unknown one, or null.
function decodeRevertData(data, depth = 0) {
  if (typeof data !== "string" || !data.startsWith("0x") || data.length < 10 || depth > 4) return null;
  let parsed;
  try {
    parsed = ERR_INTERFACE.parseError(data);
  } catch {
    parsed = null;
  }
  if (!parsed) return { selector: data.slice(0, 10) };

  if (parsed.name === "WrappedError") {
    const inner = decodeRevertData(parsed.args.reason, depth + 1) || decodeRevertData(parsed.args.details, depth + 1);
    if (inner && (inner.name || inner.selector)) {
      return { ...inner, wrappedTarget: parsed.args.target, wrappedSelector: parsed.args.selector };
    }
    return { name: "WrappedError", args: parsed.args };
  }
  return { name: parsed.name, args: parsed.args };
}

// Try to name a custom-error revert. Returns { name, args } or { selector } or null.
function parseCustomError(error) {
  if (error?.revert?.name && error.revert.name !== "WrappedError") {
    return { name: error.revert.name, args: error.revert.args };
  }
  const data = extractRevertData(error);
  if (!data) return null;
  return decodeRevertData(data);
}

const CONTRACT_ERROR_MESSAGES = {
  FillBelowEncryptedMinimum: "Fill price was below your minimum. Your funds are safe — the swap was rejected.",
  DecryptNotReady: "Waiting for encrypted result. Try revealing in a few blocks.",
  IntentAlreadyExists: "You have a pending swap. Wait for it to resolve first.",
  NonceUsed: "This intent was already submitted. Create a new swap.",
  NonceAlreadyUsed: "This intent was already submitted. Create a new swap.",
  DeadlineExpired: "Your swap intent expired. Please try again.",
  ExpiredIntent: "Your swap intent expired. Please try again.",
  Unauthorized: "You are not authorized to perform this action.",
  UnauthorizedRevealer: "Only the trader or approved compliance address can reveal.",
  InvalidIntentSignature: "Invalid trader signature on hook data.",
  InvalidHookData: "Hook data is invalid. Ensure encrypted input and intent signature are generated correctly.",
  PendingIntentExists: "Previous intent is still pending. Reveal or settle it first.",
  MissingIntent: "No swap intent found for this address.",
  RevealNotReady: "Reveal window not open yet. Wait for the required number of blocks.",
  AlreadyRevealed: "This swap has already been revealed.",
  SlippageCheckPending: "Slippage check still pending. Wait for the FHE result.",
  SolverAuctionNoBids: "No solver bids submitted for this auction.",
  SolverAuctionAlreadyQueued: "Auction is already queued for this swap.",
  SolverAuctionNotQueued: "No auction queued for this swap.",
  SolverAuctionPending: "Auction result still pending. Wait for decryption.",
  SolverAuctionAlreadyFinalized: "Auction has already been finalized.",
  SolverAuctionWinnerNotFound: "Auction winner could not be determined.",
  SolverAuctionClosed: "Auction is closed — swap already revealed.",
  DuplicateSolverBid: "You have already submitted a bid for this auction.",
  CancelDelayNotElapsed: "Cancel window not open yet. Available after ~6 hours.",
  FallbackDelayNotElapsed: "Auto-release not available yet. Available after ~24 hours.",
  AuctionTimeoutNotElapsed: "Auction cancel window not open yet. Available after ~1 hour.",
  SwapAlreadyEmergencyResolved: "This swap has already been emergency-resolved.",
  InvalidEmergencyState: "This swap is not in a state that allows emergency resolution.",
  InvalidCoFHESignature: "Encrypted result signature is invalid. Do not proceed.",
  AuctionAlreadyCancelled: "This auction has already been cancelled.",
  SurplusAlreadyRecorded: "This swap surplus was already distributed.",
};

const COFHE_ERROR_MESSAGES = {
  PermitNotFound: "No encryption permit found. Please refresh and try again.",
  EncryptionFailed: "Encryption failed. Please try again.",
  DecryptionFailed: "Decryption failed. The result may not be ready yet.",
  NetworkError: "Network error communicating with CoFHE. Please try again.",
  Timeout: "CoFHE operation timed out. Please try again.",
};

/**
 * Decode a contract error (revert) into a user-facing message.
 * Tries to match by error selector name, then falls back to string matching.
 */
export function decodeError(error) {
  if (!error) return "An unknown error occurred.";

  // First, try to decode a custom-error revert by its raw selector/data. This catches
  // errors that bubble through the swap router (which doesn't declare the hook's errors).
  const custom = parseCustomError(error);
  if (custom?.name) {
    if (custom.name === "InvalidEncryptedInput") {
      const got = custom.args?.got ?? custom.args?.[0];
      const expected = custom.args?.expected ?? custom.args?.[1];
      return `CoFHE rejected the encrypted input: type mismatch (got utype ${got}, expected ${expected}). The ciphertext's declared type does not match what the contract requested.`;
    }
    if (custom.name === "SecurityZoneOutOfBounds") {
      return `CoFHE rejected the encrypted input: security zone ${custom.args?.value ?? custom.args?.[0]} is out of bounds.`;
    }
    const mapped = CONTRACT_ERROR_MESSAGES[custom.name] || COFHE_ERROR_MESSAGES[custom.name];
    if (mapped) return mapped;
    return `Swap reverted: ${custom.name}.`;
  }
  if (custom?.selector) {
    // Not one of the known errors — likely a deeper CoFHE/coprocessor revert.
    return `Encrypted-input verification failed on-chain (unrecognized error, selector ${custom.selector}). The encrypted swap input was rejected by the coprocessor.`;
  }

  // Try to extract the revert reason from the error object
  const message = error?.shortMessage || error?.message || String(error);

  // Check for contract custom errors by name
  for (const [errorName, userMessage] of Object.entries(CONTRACT_ERROR_MESSAGES)) {
    if (message.includes(errorName)) {
      return userMessage;
    }
  }

  // Check for CoFHE errors
  for (const [errorName, userMessage] of Object.entries(COFHE_ERROR_MESSAGES)) {
    if (message.includes(errorName)) {
      return userMessage;
    }
  }

  // Common wallet/network errors
  if (message.includes("user rejected") || message.includes("User denied")) {
    return "Transaction rejected by user.";
  }
  if (message.includes("insufficient funds")) {
    return "Insufficient balance for this transaction.";
  }
  if (message.includes("nonce too high") || message.includes("replacement fee too low")) {
    return "Transaction nonce conflict. Please try again.";
  }

  // Fallback
  return message || "An unknown error occurred.";
}

/**
 * Get the user-facing message for a specific contract error name.
 * Useful when you already know the error name from a parsed revert.
 */
export function getContractErrorMessage(errorName) {
  return CONTRACT_ERROR_MESSAGES[errorName] || null;
}

/**
 * Get the user-facing message for a specific CoFHE error name.
 */
export function getCoFheErrorMessage(errorName) {
  return COFHE_ERROR_MESSAGES[errorName] || null;
}