import { useState, useEffect, useRef } from "react";
import {
  AbiCoder,
  BrowserProvider,
  Contract,
  MaxUint256,
  isAddress,
  keccak256,
  parseUnits,
} from "ethers";
import { Ghost, Lock, Eye, Shield, ChevronDown, ArrowDown, Clock, ArrowLeft } from "lucide-react";
import { TOKENS, findTokenByAddress } from "./config/tokens";
import { CONTRACTS, POOL_CONFIG, getExpectedChainId, chainNameById } from "./config/contracts";
import { POST_SETTLE_REVEAL_ABI } from "./lib/postSettleRevealAbi";
import { POOL_SWAP_TEST_ABI } from "./lib/swapAbis";
import { shortAddress, toNumberSafe } from "./lib/format";
import { encryptMinOut, mapCofheError } from "./hooks/useCofhe";

const SwapState = {
  IDLE: "idle",
  ENCRYPTING: "encrypting",
  SUBMITTED: "submitted",
  SETTLING: "settling",
  PENDING_REVEAL: "pending_reveal",
  REVEALED: "revealed",
};

const HOOK_NONCE_STORAGE_KEY = "ghostswap:hook-nonce";
const TRACKED_SWAP_STORAGE_KEY = "ghostswap:tracked-swaps";
const HISTORY_PAGE_SIZE = 8;
const HISTORY_LOOKBACK_BLOCKS = 100_000;
const MIN_SQRT_PRICE_LIMIT_X96 = 4295128740n;
const MAX_SQRT_PRICE_LIMIT_X96 = 1461446703485210103287273052203988822378723970341n;
const INTENT_SIGNING_DOMAIN = {
  name: "GhostSwapIntent",
  version: "1",
};
const INTENT_DEADLINE_SECONDS = Number(import.meta.env.VITE_INTENT_DEADLINE_SECONDS || 20 * 60);
const INTENT_AUTHORIZATION_TYPES = {
  IntentAuthorization: [
    { name: "trader", type: "address" },
    { name: "sender", type: "address" },
    { name: "poolId", type: "bytes32" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "ctHash", type: "uint256" },
  ],
};
const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function approve(address spender,uint256 amount) returns (bool)",
];

function toStorageKey(address, chainId) {
  return `${String(address).toLowerCase()}:${chainId}`;
}

function toTrackedSwapStorageKey(address, chainId, hookAddress) {
  return `${toStorageKey(address, chainId)}:${String(hookAddress).toLowerCase()}`;
}

function normalizeSwapIds(swapIds) {
  return Array.from(new Set((swapIds || []).map((swapId) => Number(swapId)).filter((swapId) => Number.isFinite(swapId) && swapId > 0)))
    .sort((left, right) => right - left);
}

function getStoredHookNonce(address, chainId) {
  if (!address || !chainId) return 1;
  try {
    const raw = localStorage.getItem(HOOK_NONCE_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    const current = Number(parsed[toStorageKey(address, chainId)] || 1);
    return Number.isFinite(current) && current > 0 ? current : 1;
  } catch {
    return 1;
  }
}

function setStoredHookNonce(address, chainId, nonce) {
  if (!address || !chainId) return;
  try {
    const raw = localStorage.getItem(HOOK_NONCE_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    parsed[toStorageKey(address, chainId)] = nonce;
    localStorage.setItem(HOOK_NONCE_STORAGE_KEY, JSON.stringify(parsed));
  } catch {
    // Ignore storage errors and let submit continue.
  }
}

function getTrackedSwapIds(address, chainId, hookAddress) {
  if (!address || !chainId || !hookAddress) return [];
  try {
    const raw = localStorage.getItem(TRACKED_SWAP_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    return normalizeSwapIds(parsed[toTrackedSwapStorageKey(address, chainId, hookAddress)]);
  } catch {
    return [];
  }
}

function setTrackedSwapIds(address, chainId, hookAddress, swapIds) {
  if (!address || !chainId || !hookAddress) return;
  try {
    const raw = localStorage.getItem(TRACKED_SWAP_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    const storageKey = toTrackedSwapStorageKey(address, chainId, hookAddress);
    const normalized = normalizeSwapIds(swapIds);

    if (normalized.length > 0) {
      parsed[storageKey] = normalized;
    } else {
      delete parsed[storageKey];
    }

    localStorage.setItem(TRACKED_SWAP_STORAGE_KEY, JSON.stringify(parsed));
  } catch {
    // Ignore storage errors and let submit continue.
  }
}

function addTrackedSwapId(address, chainId, hookAddress, swapId) {
  setTrackedSwapIds(address, chainId, hookAddress, [swapId, ...getTrackedSwapIds(address, chainId, hookAddress)]);
}

function getSqrtPriceLimitX96(zeroForOne) {
  return zeroForOne ? MIN_SQRT_PRICE_LIMIT_X96 + 1n : MAX_SQRT_PRICE_LIMIT_X96 - 1n;
}

function computePoolId({ token0, token1, fee, tickSpacing, hooks }) {
  return keccak256(
    AbiCoder.defaultAbiCoder().encode(["address", "address", "uint24", "int24", "address"], [token0, token1, fee, tickSpacing, hooks])
  );
}

function mapSubmitError(error) {
  const cofheError = mapCofheError(error);
  if (cofheError && cofheError !== "CoFHE operation failed.") {
    return cofheError;
  }

  const message = error?.shortMessage || error?.message || "Swap submission failed.";
  if (message.includes("NonceUsed")) return "Nonce already used. Retry once to use the next nonce.";
  if (message.includes("PendingIntentExists")) return "Previous intent is still pending. Reveal or settle it first.";
  if (message.includes("InvalidHookData")) return "Hook data is invalid. Ensure encrypted input and intent signature are generated correctly.";
  if (message.includes("ExpiredIntent")) return "Intent signature expired. Retry the swap.";
  if (message.includes("InvalidIntentSignature")) return "Invalid trader signature on hook data.";
  return message;
}

function Noise() {
  return (
    <svg className="fixed w-0 h-0">
      <filter id="noise">
        <feTurbulence type="fractalNoise" baseFrequency="0.65" numOctaves="3" stitchTiles="stitch" />
        <feColorMatrix type="saturate" values="0" />
        <feBlend in="SourceGraphic" mode="overlay" result="blend" />
        <feComposite in="blend" in2="SourceGraphic" operator="in" />
      </filter>
    </svg>
  );
}

function TokenSelector({ selected, onSelect, disabled = false }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    function handle(e) {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    }
    document.addEventListener("mousedown", handle);
    return () => document.removeEventListener("mousedown", handle);
  }, []);

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => {
          if (!disabled) setOpen(!open);
        }}
        disabled={disabled}
        className={`flex items-center gap-[6px] bg-white/5 border border-white/10 rounded-sm px-3 py-2 text-[15px] font-mono font-medium transition-colors duration-150 whitespace-nowrap ${
          disabled
            ? "text-ghost-text-dim cursor-not-allowed opacity-70"
            : "text-ghost-text-primary cursor-pointer hover:bg-white/10"
        }`}
      >
        <span className="text-[18px] leading-none">{selected.icon}</span>
        <span>{selected.symbol}</span>
        <ChevronDown size={16} fill="currentColor" />
      </button>

      {open && !disabled && (
        <div className="absolute top-[calc(100%+6px)] left-0 bg-ghost-card border border-white/10 rounded-sm overflow-hidden z-[100] min-w-[160px] shadow-[0_20px_40px_rgba(0,0,0,0.6)]">
          {TOKENS.map(t => (
            <button
              key={t.symbol}
              onClick={() => {
                if (!disabled) {
                  onSelect(t);
                  setOpen(false);
                }
              }}
              disabled={disabled}
              className={`flex items-center gap-2.5 w-full px-3.5 py-2.5 border-none cursor-pointer text-[14px] font-mono text-left transition-colors duration-100 ${
                selected.symbol === t.symbol 
                  ? 'bg-ghost-gold/10 text-ghost-gold' 
                  : 'bg-transparent text-ghost-text-secondary hover:bg-white/5'
              }`}
            >
              <span className="text-[18px]">{t.icon}</span>
              <div>
                <div className={`font-medium ${selected.symbol === t.symbol ? 'text-ghost-gold' : 'text-ghost-text-primary'}`}>
                  {t.symbol}
                </div>
                <div className="text-[11px] text-ghost-text-muted">{t.name}</div>
              </div>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function StatusBadge({ state }) {
  const configs = {
    [SwapState.IDLE]: null,
    [SwapState.ENCRYPTING]: { label: "Encrypting intent", dotClass: "bg-ghost-gold animate-pulse-slow", wrapperClass: "text-ghost-gold bg-ghost-gold/5 border-ghost-gold/20" },
    [SwapState.SUBMITTED]: { label: "Submitted to mempool", dotClass: "bg-ghost-gold animate-pulse-slow", wrapperClass: "text-ghost-gold bg-ghost-gold/5 border-ghost-gold/20" },
    [SwapState.SETTLING]: { label: "Settling on-chain", dotClass: "bg-ghost-gold animate-pulse-slow", wrapperClass: "text-ghost-gold bg-ghost-gold/5 border-ghost-gold/20" },
    [SwapState.PENDING_REVEAL]: { label: "Awaiting reveal window", dotClass: "bg-ghost-green", wrapperClass: "text-ghost-green bg-ghost-green/5 border-ghost-green/20" },
    [SwapState.REVEALED]: { label: "Trade revealed", dotClass: "bg-ghost-green", wrapperClass: "text-ghost-green bg-ghost-green/5 border-ghost-green/20" },
  };

  const cfg = configs[state];
  if (!cfg) return null;

  return (
    <div className={`flex items-center gap-2 px-3.5 py-2 border rounded-sm text-[12px] font-mono ${cfg.wrapperClass}`}>
      <span className={`w-1.5 h-1.5 rounded-full inline-block ${cfg.dotClass}`} />
      {cfg.label}
    </div>
  );
}

function MempoolComparison({ visible }) {
  if (!visible) return null;

  return (
    <div className="mt-6 grid grid-cols-1 md:grid-cols-2 gap-3 w-full animate-fade-up">
      {[
        {
          label: "Regular Uniswap",
          bad: true,
          fields: [
            { key: "amountIn", value: "1000000000000000000" },
            { key: "amountOutMinimum", value: "3198000000" },
            { key: "recipient", value: "0x742d...4f2b" },
          ]
        },
        {
          label: "GhostSwap",
          bad: false,
          fields: [
            { key: "amountIn", value: "0x3f8a2c9d..." },
            { key: "amountOutMinimum", value: "0x7b2e4f1a..." },
            { key: "recipient", value: "0x742d...4f2b" },
          ]
        }
      ].map(panel => (
        <div key={panel.label} className={`border rounded-sm p-3.5 ${panel.bad ? "bg-ghost-red/5 border-ghost-red/20" : "bg-ghost-green/5 border-ghost-green/20"}`}>
          <div className={`text-[10px] font-mono mb-2.5 tracking-[0.08em] uppercase flex items-center gap-1.5 ${panel.bad ? "text-[#b43c3c]" : "text-ghost-green"}`}>
            {panel.bad ? "⚠" : <Shield size={12} fill="currentColor" />}
            {panel.label}
          </div>
          {panel.fields.map(f => (
            <div key={f.key} className="mb-1.5">
              <div className="text-[9px] text-ghost-text-muted font-mono mb-0.5">{f.key}</div>
              <div className={`text-[11px] font-mono bg-black/30 px-2 py-1 rounded-sm break-all ${
                panel.bad && f.key === "amountOutMinimum" ? "text-ghost-red" : 
                panel.bad ? "text-[#7a7068]" : 
                f.key === "amountOutMinimum" ? "text-ghost-green" : "text-[#7a7068]"
              }`}>
                {f.value}
              </div>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function TransactionHistory({ visible, entries, page, totalPages, onPrevPage, onNextPage, onReveal, loading }) {
  const [open, setOpen] = useState(false);

  if (!visible) return null;

  return (
    <div className="w-full mt-6 bg-ghost-card/90 border border-white/10 rounded-sm">
      <button 
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between p-4 cursor-pointer hover:bg-white/5 transition-colors border-none bg-transparent"
      >
        <span className="text-[11px] uppercase tracking-[0.1em] text-ghost-text-secondary">Recent Trades</span>
        <ChevronDown size={14} className={`text-ghost-text-secondary transform transition-transform ${open ? "rotate-180" : ""}`} />
      </button>

      {open && (
        <div className="border-t border-white/5 p-4 flex flex-col gap-3 animate-fade-up">
          {loading && <div className="text-[11px] text-ghost-text-dim">Loading on-chain history...</div>}

          {entries.length === 0 && (
            <div className="text-[11px] text-ghost-text-dim">No on-chain swaps detected yet.</div>
          )}

          {entries.map((entry) => (
            <div
              key={entry.id}
              className={`text-[11px] flex items-center gap-2 ${entry.revealed ? "text-ghost-green" : "text-[#7a7068]"}`}
            >
              {entry.revealed ? <span className="text-sm">✓</span> : <Lock size={12} fill="currentColor" />}
              {entry.text}
              {!entry.revealed && entry.tracked && entry.canReveal && (
                <button
                  onClick={() => onReveal(entry.id)}
                  className="bg-transparent border-none text-ghost-gold hover:underline cursor-pointer p-0 ml-1"
                >
                  Reveal
                </button>
              )}
            </div>
          ))}

          {totalPages > 1 && (
            <div className="mt-1 flex items-center justify-between border-t border-white/5 pt-3">
              <button
                onClick={onPrevPage}
                disabled={page <= 0}
                className="bg-transparent border-none text-ghost-text-secondary hover:text-ghost-text-primary disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer text-[11px]"
              >
                Newer
              </button>
              <span className="text-[10px] text-ghost-text-muted">
                Page {page + 1} / {totalPages}
              </span>
              <button
                onClick={onNextPage}
                disabled={page >= totalPages - 1}
                className="bg-transparent border-none text-ghost-text-secondary hover:text-ghost-text-primary disabled:opacity-40 disabled:cursor-not-allowed cursor-pointer text-[11px]"
              >
                Older
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function PendingRevealPanel({ swap, currentBlock, onReveal }) {
  if (!swap) return null;

  const readyBlock = swap.decryptReadyBlock || 0;
  const settledAtBlock = swap.settledAtBlock || 0;
  const blocksRemaining = Math.max(readyBlock - currentBlock, 0);
  const canReveal = swap.canReveal || blocksRemaining <= 0;
  const totalRevealDelay = readyBlock > settledAtBlock ? readyBlock - settledAtBlock : 0;
  const elapsedRevealDelay = totalRevealDelay > 0 ? Math.min(totalRevealDelay, Math.max(currentBlock - settledAtBlock, 0)) : 0;
  const progressSegments = totalRevealDelay > 0 ? Math.max(0, Math.min(15, Math.round((elapsedRevealDelay / totalRevealDelay) * 15))) : 0;

  return (
    <div className="mt-5 border border-ghost-green/15 bg-ghost-green/5 rounded-sm p-4 animate-fade-up">
      <div className="flex items-center justify-between gap-3 mb-3">
        <div className="flex items-center gap-2 text-ghost-green text-[11px] uppercase tracking-[0.1em]">
          <span className="w-2 h-2 rounded-full bg-ghost-green inline-block" />
          Awaiting reveal window
        </div>
        <div className="text-[10px] text-[#89a489] font-mono">Swap #{swap.id}</div>
      </div>

      <div className="text-[11px] text-[#7a8c7a] mb-2 flex items-center gap-1.5">
        <Clock size={12} fill="currentColor" />
        Block #{currentBlock || "-"} {"->"} Reveal at #{readyBlock || "-"}
      </div>

      {totalRevealDelay > 0 ? (
        <div className="flex items-center justify-between gap-4 mb-3">
          <div className="text-ghost-gold text-[12px] font-mono tracking-widest">
            [{"█".repeat(progressSegments)}{"░".repeat(Math.max(0, 15 - progressSegments))}]
          </div>
          <div className="text-[10px] text-ghost-text-muted whitespace-nowrap">
            {elapsedRevealDelay} of {totalRevealDelay} blocks
          </div>
        </div>
      ) : (
        <div className="text-[10px] text-ghost-text-muted mb-3">
          Reveal in {blocksRemaining} block{blocksRemaining === 1 ? "" : "s"}.
        </div>
      )}

      <div className="text-[10px] text-[#718271] mb-3">
        Only swaps submitted from this wallet/browser are surfaced here.
      </div>

      <button
        onClick={() => onReveal(swap.id)}
        disabled={!canReveal}
        className={`w-full p-4 rounded-sm text-[13px] font-mono font-medium tracking-[0.08em] uppercase flex items-center justify-center gap-2 transition-all duration-150 ${
          canReveal
            ? "bg-gradient-to-br from-[#4a7a4a] to-[#2d5a2d] border-none text-[#e8f5e8] cursor-pointer hover:brightness-110 active:scale-[0.98]"
            : "bg-ghost-green/5 border border-ghost-green/15 text-[#4a6a4a] cursor-not-allowed"
        }`}
      >
        <Eye size={16} fill="currentColor" />
        {canReveal ? "Reveal My Trade" : `Reveal in ${blocksRemaining} blocks`}
      </button>
    </div>
  );
}

export default function GhostSwap({ onBack }) {
  const expectedChainId = getExpectedChainId();
  const hasHookConfig = Boolean(CONTRACTS.postSettleRevealHook);
  const hasSwapConfig = Boolean(CONTRACTS.swapRouter);

  const defaultTokenIn = TOKENS[0];
  const defaultTokenOut = TOKENS[1];
  const [tokenIn, setTokenIn] = useState(defaultTokenIn);
  const [tokenOut, setTokenOut] = useState(defaultTokenOut);
  const [amountIn, setAmountIn] = useState("");
  const [minOut, setMinOut] = useState("");
  const [swapState, setSwapState] = useState(SwapState.IDLE);
  const [showMempool, setShowMempool] = useState(false);
  const [currentBlock, setCurrentBlock] = useState(0);
  const [trackedPendingSwap, setTrackedPendingSwap] = useState(null);
  const [history, setHistory] = useState([]);
  const [historyPage, setHistoryPage] = useState(0);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [revealData, setRevealData] = useState(null);
  const [complianceAddr, setComplianceAddr] = useState("");
  const [showCompliance, setShowCompliance] = useState(false);
  const [wallet, setWallet] = useState(null);
  const [chainLabel, setChainLabel] = useState("NOT CONNECTED");
  const [uiError, setUiError] = useState("");
  const [uiNotice, setUiNotice] = useState(null);
  const disconnectingRef = useRef(false);

  const poolToken0 = findTokenByAddress(POOL_CONFIG.token0);
  const poolToken1 = findTokenByAddress(POOL_CONFIG.token1);
  const hasPoolConfig = Boolean(POOL_CONFIG.token0 && POOL_CONFIG.token1 && hasHookConfig);
  const historyPages = Math.max(1, Math.ceil(history.length / HISTORY_PAGE_SIZE));
  const historyPageStart = historyPage * HISTORY_PAGE_SIZE;
  const visibleHistory = history.slice(historyPageStart, historyPageStart + HISTORY_PAGE_SIZE);

  const configIssues = [];
  if (!hasHookConfig) configIssues.push("Missing VITE_POST_SETTLE_HOOK");
  if (!hasSwapConfig) configIssues.push("Missing VITE_SWAP_ROUTER");
  if (!POOL_CONFIG.token0) configIssues.push("Missing VITE_POOL_TOKEN0");
  if (!POOL_CONFIG.token1) configIssues.push("Missing VITE_POOL_TOKEN1");
  if (!poolToken0 && POOL_CONFIG.token0) configIssues.push("VITE_POOL_TOKEN0 is not mapped in token metadata");
  if (!poolToken1 && POOL_CONFIG.token1) configIssues.push("VITE_POOL_TOKEN1 is not mapped in token metadata");

  useEffect(() => {
    if (poolToken0 && poolToken1) {
      setTokenIn(poolToken0);
      setTokenOut(poolToken1);
    }
  }, [poolToken0, poolToken1]);

  useEffect(() => {
    if (historyPage >= historyPages) {
      setHistoryPage(Math.max(0, historyPages - 1));
    }
  }, [historyPage, historyPages]);

  function clearSyncState() {
    setSwapState(SwapState.IDLE);
    setShowMempool(false);
    setCurrentBlock(0);
    setTrackedPendingSwap(null);
    setRevealData(null);
    setHistory([]);
    setHistoryPage(0);
    setHistoryLoading(false);
  }

  function clearComposeState() {
    setAmountIn("");
    setMinOut("");
    setComplianceAddr("");
    setShowCompliance(false);
  }

  function clearLocalSession(notice = null) {
    clearSyncState();
    clearComposeState();
    setWallet(null);
    setChainLabel("NOT CONNECTED");
    setUiError("");
    setUiNotice(notice);
  }

  async function syncInjectedWallet({ requestAccounts = false, clearNotice = true } = {}) {
    if (clearNotice) {
      setUiNotice(null);
    }

    setUiError("");

    if (!window.ethereum) {
      setUiError("No injected wallet detected. Install MetaMask or a compatible wallet.");
      return null;
    }

    try {
      const provider = new BrowserProvider(window.ethereum);

      if (requestAccounts) {
        await provider.send("eth_requestAccounts", []);
      }

      const accounts = await provider.send("eth_accounts", []);
      if (!accounts.length) {
        clearLocalSession();
        return null;
      }

      const signer = await provider.getSigner();
      const address = await signer.getAddress();
      const network = await provider.getNetwork();
      const chainId = toNumberSafe(network.chainId);

      setWallet({ provider, signer, address, chainId });
      setChainLabel(chainNameById(chainId));
      setRevealData(null);

      if (chainId !== expectedChainId) {
        clearSyncState();
        setWallet({ provider, signer, address, chainId });
        setChainLabel(chainNameById(chainId));
        setUiError(`Wrong network. Expected chain id ${expectedChainId}, got ${chainId}.`);
        return { provider, signer, address, chainId };
      }

      await syncLatestSwap(provider, address, chainId);
      return { provider, signer, address, chainId };
    } catch (error) {
      setUiError(error?.shortMessage || error?.message || "Wallet connection failed.");
      return null;
    }
  }

  async function connectWallet() {
    await syncInjectedWallet({ requestAccounts: true });
  }

  async function disconnectWallet() {
    let notice = {
      tone: "warning",
      text: "Disconnected in app. If MetaMask still shows GhostSwap as connected, use All Permissions -> GhostSwap -> Disconnect.",
    };

    disconnectingRef.current = true;
    setUiError("");

    try {
      if (window.ethereum?.request) {
        await window.ethereum.request({
          method: "wallet_revokePermissions",
          params: [{ eth_accounts: {} }],
        });

        const remainingAccounts = await window.ethereum.request({ method: "eth_accounts" });
        if (!Array.isArray(remainingAccounts) || remainingAccounts.length === 0) {
          notice = {
            tone: "success",
            text: "Disconnected from wallet and app.",
          };
        }
      }
    } catch {
      // Fall back to a local disconnect below and show the manual MetaMask path.
    }

    clearLocalSession(notice);

    window.setTimeout(() => {
      disconnectingRef.current = false;
    }, 0);
  }

  function getHookContract(providerOrSigner) {
    if (!hasHookConfig) return null;
    return new Contract(CONTRACTS.postSettleRevealHook, POST_SETTLE_REVEAL_ABI, providerOrSigner);
  }

  function getSwapRouterContract(signer) {
    if (!CONTRACTS.swapRouter) return null;
    return new Contract(CONTRACTS.swapRouter, POOL_SWAP_TEST_ABI, signer);
  }

  function getErc20(tokenAddress, providerOrSigner) {
    return new Contract(tokenAddress, ERC20_ABI, providerOrSigner);
  }

  async function ensureTransferReadiness(amountRaw) {
    const address = wallet?.address;
    const signer = wallet?.signer;
    if (!address || !signer || !tokenIn.address) {
      throw new Error("Wallet and token are required before submit.");
    }

    const token = getErc20(tokenIn.address, signer);
    const [balance, allowance] = await Promise.all([
      token.balanceOf(address),
      token.allowance(address, CONTRACTS.swapRouter),
    ]);

    if (balance < amountRaw) {
      throw new Error(`Insufficient ${tokenIn.symbol} balance for this swap.`);
    }

    if (allowance < amountRaw) {
      const approveTx = await token.approve(CONTRACTS.swapRouter, MaxUint256);
      await approveTx.wait();
    }
  }

  async function buildHookData(minOutRaw, traderAddress) {
    const chainId = wallet?.chainId;
    if (!wallet?.signer || !chainId) {
      throw new Error("Wallet signer is required to build encrypted hook data.");
    }

    const nonce = getStoredHookNonce(traderAddress, chainId);
    const deadline = Math.floor(Date.now() / 1000) + INTENT_DEADLINE_SECONDS;
    const encryptedMinOutInput = await encryptMinOut({
      minOutRaw,
      chainId,
      traderAddress,
      ethereumProvider: window.ethereum,
    });

    const poolId = computePoolId({
      token0: POOL_CONFIG.token0,
      token1: POOL_CONFIG.token1,
      fee: POOL_CONFIG.fee,
      tickSpacing: POOL_CONFIG.tickSpacing,
      hooks: CONTRACTS.postSettleRevealHook,
    });

    const intentSignature = await wallet.signer.signTypedData(
      {
        ...INTENT_SIGNING_DOMAIN,
        chainId,
        verifyingContract: CONTRACTS.postSettleRevealHook,
      },
      INTENT_AUTHORIZATION_TYPES,
      {
        trader: traderAddress,
        sender: CONTRACTS.swapRouter,
        poolId,
        nonce: BigInt(nonce),
        deadline: BigInt(deadline),
        ctHash: BigInt(encryptedMinOutInput.ctHash),
      }
    );

    const hookData = AbiCoder.defaultAbiCoder().encode(
      ["tuple(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature)", "uint256", "address", "uint256", "bytes"],
      [
        [
          BigInt(encryptedMinOutInput.ctHash),
          Number(encryptedMinOutInput.securityZone),
          Number(encryptedMinOutInput.utype),
          encryptedMinOutInput.signature,
        ],
        BigInt(nonce),
        traderAddress,
        BigInt(deadline),
        intentSignature,
      ]
    );

    setStoredHookNonce(traderAddress, chainId, nonce + 1);

    return { hookData, nonce };
  }

  async function submitSwap() {
    if (!wallet?.signer) {
      setUiError("Connect wallet first.");
      return;
    }

    if (!hasPoolConfig || !hasSwapConfig) {
      setUiError("Swap config missing. Set pool token addresses and swap router env vars.");
      return;
    }

    if (!amountIn || !minOut) {
      setUiError("Enter amount in and minimum output.");
      return;
    }

    if (!tokenIn.address || !tokenOut.address) {
      setUiError("Selected tokens are missing configured addresses.");
      return;
    }

    const zeroForOne = tokenIn.address.toLowerCase() === POOL_CONFIG.token0.toLowerCase();
    if (!zeroForOne && tokenIn.address.toLowerCase() !== POOL_CONFIG.token1.toLowerCase()) {
      setUiError("Token pair does not match configured pool currencies.");
      return;
    }

    try {
      setUiError("");
      setUiNotice(null);
      setShowMempool(true);
      setSwapState(SwapState.ENCRYPTING);

      const amountSpecified = -parseUnits(amountIn, tokenIn.decimals);
      const minOutRaw = parseUnits(minOut, tokenOut.decimals);
      const sqrtPriceLimitX96 = getSqrtPriceLimitX96(zeroForOne);
      const complianceAddress = complianceAddr.trim();

      if (complianceAddress && !isAddress(complianceAddress)) {
        throw new Error("Compliance address is invalid.");
      }

      await ensureTransferReadiness(-amountSpecified);

      const { hookData } = await buildHookData(minOutRaw, wallet.address);

      const hook = getHookContract(wallet.signer);
      if (complianceAddress) {
        const authTx = await hook.setAuthorizedRevealer(complianceAddress, true);
        await authTx.wait();
      }

      setSwapState(SwapState.SUBMITTED);

      const swapRouter = getSwapRouterContract(wallet.signer);
      const tx = await swapRouter.swap(
        {
          currency0: POOL_CONFIG.token0,
          currency1: POOL_CONFIG.token1,
          fee: POOL_CONFIG.fee,
          tickSpacing: POOL_CONFIG.tickSpacing,
          hooks: CONTRACTS.postSettleRevealHook,
        },
        {
          zeroForOne,
          amountSpecified,
          sqrtPriceLimitX96,
        },
        {
          takeClaims: POOL_CONFIG.takeClaims,
          settleUsingBurn: POOL_CONFIG.settleUsingBurn,
        },
        hookData
      );

      setSwapState(SwapState.SETTLING);
      const receipt = await tx.wait();

      let trackedSwapId = 0;
      for (const log of receipt?.logs || []) {
        if (log.address?.toLowerCase() !== CONTRACTS.postSettleRevealHook.toLowerCase()) continue;
        try {
          const parsedLog = hook.interface.parseLog({ topics: log.topics, data: log.data });
          if (parsedLog?.name === "SettlementRecorded") {
            trackedSwapId = Number(parsedLog.args?.swapId ?? parsedLog.args?.[0] ?? 0);
            break;
          }
        } catch {
          // Ignore non-hook logs from the receipt.
        }
      }

      if (trackedSwapId > 0) {
        addTrackedSwapId(wallet.address, wallet.chainId, CONTRACTS.postSettleRevealHook, trackedSwapId);
      } else {
        setUiNotice({
          tone: "warning",
          text: "Swap settled, but GhostSwap could not recover its swap ID from the receipt. Use Sync Latest Swap if the reveal panel does not appear.",
        });
      }

      await syncLatestSwap(wallet.provider, wallet.address, wallet.chainId);
    } catch (error) {
      setSwapState(SwapState.IDLE);
      setUiError(mapSubmitError(error));
    }
  }

  async function syncLatestSwap(providerOverride, addressOverride, chainIdOverride) {
    setUiError("");

    const provider = providerOverride || wallet?.provider;
    const address = addressOverride || wallet?.address;
    const chainId = chainIdOverride || wallet?.chainId;

    if (!provider || !address || !chainId || !hasHookConfig) return;

    try {
      const hook = getHookContract(provider);
      setHistoryLoading(true);

      const hookCode = await provider.getCode(CONTRACTS.postSettleRevealHook);
      if (!hookCode || hookCode === "0x") {
        setUiError("Configured hook contract is not deployed on the currently connected chain. Re-run local setup and reconnect wallet.");
        setHistory([]);
        setTrackedPendingSwap(null);
        setRevealData(null);
        setSwapState(SwapState.IDLE);
        setCurrentBlock(0);
        return;
      }

      const block = await provider.getBlockNumber();
      setCurrentBlock(block);

      const nextSwapId = toNumberSafe(await hook.nextSwapId());
      const trackedSwapIds = getTrackedSwapIds(address, chainId, CONTRACTS.postSettleRevealHook);

      if (nextSwapId <= 1) {
        setHistory([]);
        setTrackedPendingSwap(null);
        setRevealData(null);
        setSwapState(SwapState.IDLE);
        setTrackedSwapIds(address, chainId, CONTRACTS.postSettleRevealHook, []);
        return;
      }

      const latestFromBlock = Math.max(0, block - HISTORY_LOOKBACK_BLOCKS);
      const [settlementLogs, revealLogs] = await Promise.all([
        hook.queryFilter(hook.filters.SettlementRecorded(), latestFromBlock, block),
        hook.queryFilter(hook.filters.Revealed(), latestFromBlock, block),
      ]);

      const revealedIds = new Set(revealLogs.map((log) => Number(log.args?.swapId ?? log.args?.[0])));
      const recentSwapIds = Array.from(new Set(settlementLogs.map((log) => Number(log.args?.swapId ?? log.args?.[0]))))
        .filter((id) => Number.isFinite(id) && id > 0)
        .sort((a, b) => b - a);

      const idsToHydrate = normalizeSwapIds([
        ...trackedSwapIds,
        ...(recentSwapIds.length > 0 ? recentSwapIds : [nextSwapId - 1]),
      ]).slice(0, Math.max(64, trackedSwapIds.length || 1));

      const hydratedRecords = await Promise.all(
        idsToHydrate.map(async (swapId) => {
          try {
            const [intent, settlement] = await Promise.all([
              hook.getSwapIntent(swapId),
              hook.getSettlementRecord(swapId),
            ]);

            const state = toNumberSafe(intent[4]);
            const settledAtBlock = toNumberSafe(settlement[4]);
            const decryptReadyBlock = toNumberSafe(settlement[5]);
            const amountSpecified = settlement[3].toString();
            const isRevealed = state === 4 || revealedIds.has(swapId);

            return {
              id: swapId,
              trader: intent[0],
              state,
              settledAtBlock,
              decryptReadyBlock,
              amountSpecified,
              delta0: settlement[1].toString(),
              delta1: settlement[2].toString(),
              revealed: isRevealed,
              canReveal: (state === 2 || state === 3) && block >= decryptReadyBlock,
            };
          } catch {
            return null;
          }
        })
      );

      const records = hydratedRecords.filter(Boolean);
      const sorted = records.sort((a, b) => b.id - a.id);
      const trackedSwapIdSet = new Set(trackedSwapIds);
      const recordsById = new Map(sorted.map((entry) => [entry.id, entry]));
      const trackedRecords = trackedSwapIds.map((swapId) => recordsById.get(swapId)).filter(Boolean);
      const pendingTracked = trackedRecords.find((entry) => !entry.revealed);
      const latestTrackedResolved = trackedRecords.find((entry) => entry.revealed);
      const unresolvedTrackedIds = trackedRecords.filter((entry) => !entry.revealed).map((entry) => entry.id);

      setTrackedSwapIds(address, chainId, CONTRACTS.postSettleRevealHook, unresolvedTrackedIds);

      setHistory(
        sorted.map((entry) => ({
          id: entry.id,
          tracked: trackedSwapIdSet.has(entry.id),
          revealed: entry.revealed,
          canReveal: entry.canReveal,
          text: entry.revealed
            ? `Swap #${entry.id} revealed · delta0 ${entry.delta0} · delta1 ${entry.delta1}`
            : `Swap #${entry.id} pending reveal${trackedSwapIdSet.has(entry.id) ? " · tracked" : ""} · recorded sender ${shortAddress(entry.trader)} · block #${entry.settledAtBlock}`,
        }))
      );

      if (pendingTracked) {
        setTrackedPendingSwap({
          ...pendingTracked,
          canReveal: pendingTracked.canReveal || block >= pendingTracked.decryptReadyBlock,
        });
        setRevealData(null);
        setSwapState(SwapState.IDLE);
      } else if (latestTrackedResolved) {
        setTrackedPendingSwap(null);
        setSwapState(SwapState.REVEALED);
        setRevealData({
          amountIn: amountIn || "-",
          tokenIn: tokenIn.symbol,
          amountOut: "-",
          tokenOut: tokenOut.symbol,
          executionPrice: "-",
          surplus: "-",
          block: latestTrackedResolved.settledAtBlock ? String(latestTrackedResolved.settledAtBlock) : "-",
          txHash: "On-chain",
        });
      } else {
        setTrackedPendingSwap(null);
        setRevealData(null);
        setSwapState(SwapState.IDLE);
      }
    } catch (error) {
      setUiError(error?.shortMessage || error?.message || "Failed to sync latest swap.");
    } finally {
      setHistoryLoading(false);
    }
  }

  useEffect(() => {
    if (!trackedPendingSwap || !wallet?.provider) return;

    const interval = setInterval(() => {
      wallet.provider
        .getBlockNumber()
        .then((block) => {
          setCurrentBlock(block);
        })
        .catch(() => {
          // Ignore polling hiccups and try again on next tick.
        });
    }, 2000);

    return () => clearInterval(interval);
  }, [trackedPendingSwap, wallet]);

  useEffect(() => {
    if (!window.ethereum?.on) return undefined;

    const handleAccountsChanged = async (accounts) => {
      if (!accounts?.length) {
        if (disconnectingRef.current) {
          disconnectingRef.current = false;
          return;
        }

        clearLocalSession({
          tone: "success",
          text: "Wallet disconnected.",
        });
        return;
      }

      await syncInjectedWallet({ clearNotice: true });
    };

    const handleChainChanged = async () => {
      await syncInjectedWallet({ clearNotice: true });
    };

    window.ethereum.on("accountsChanged", handleAccountsChanged);
    window.ethereum.on("chainChanged", handleChainChanged);

    return () => {
      window.ethereum.removeListener?.("accountsChanged", handleAccountsChanged);
      window.ethereum.removeListener?.("chainChanged", handleChainChanged);
    };
  }, []);

  const simulate = async () => {
    console.log("[GhostSwap] Sync Latest Swap clicked");

    if (!wallet) {
      setUiError("Connect wallet first.");
      return;
    }
    await syncLatestSwap();
  };

  const reveal = async (swapIdOverride) => {
    const swapId = swapIdOverride || trackedPendingSwap?.id;
    if (!wallet?.signer || !swapId) {
      setUiError("No revealable swap detected yet.");
      return;
    }

    try {
      setUiError("");
      setUiNotice(null);
      const hook = getHookContract(wallet.signer);
      const tx = await hook.revealSwapDetails(swapId);
      await tx.wait();
      await syncLatestSwap();
    } catch (error) {
      setUiError(error?.shortMessage || error?.message || "Reveal transaction failed.");
    }
  };

  const reset = () => {
    setSwapState(SwapState.IDLE);
    setShowMempool(false);
    setRevealData(null);
    setAmountIn("");
    setMinOut("");
    setTrackedPendingSwap(null);
  };

  const isBusy =
    swapState === SwapState.ENCRYPTING ||
    swapState === SwapState.SUBMITTED ||
    swapState === SwapState.SETTLING;
  const displaySwapState = isBusy
    ? swapState
    : trackedPendingSwap
      ? SwapState.PENDING_REVEAL
      : swapState === SwapState.REVEALED
        ? SwapState.REVEALED
        : SwapState.IDLE;
  const canSwap =
    wallet &&
    wallet.chainId === expectedChainId &&
    hasHookConfig &&
    hasSwapConfig &&
    hasPoolConfig &&
    !isBusy &&
    Number(amountIn) > 0 &&
    Number(minOut) > 0;

  return (
    <div className="min-h-screen bg-ghost-bg flex flex-col items-center pt-8 md:pt-10 px-4 md:px-5 pb-20 font-mono relative overflow-hidden" 
         style={{ backgroundImage: "radial-gradient(ellipse 60% 40% at 50% -10%, rgba(212,163,89,0.08) 0%, transparent 60%), radial-gradient(ellipse 40% 30% at 80% 80%, rgba(100,80,40,0.05) 0%, transparent 50%)" }}>
      
      <Noise />

      {/* Scanline effect */}
      <div className="fixed inset-0 pointer-events-none z-0 overflow-hidden opacity-[0.03]">
        <div className="absolute w-full h-[2px] bg-ghost-gold/80 animate-scan" style={{ animationDuration: '8s' }} />
      </div>

      {/* Top Header Controls (Back & Wallet) */}
      <div className="w-full flex justify-between items-center mb-6 relative z-10 px-2 md:px-4">
        <button 
          onClick={onBack}
          className="bg-transparent border-none text-ghost-gold text-[13px] tracking-[0.08em] uppercase flex items-center gap-2 cursor-pointer hover:underline p-0"
        >
          <ArrowLeft size={14} /> Back
        </button>
        
        {wallet ? (
          <div className="flex items-center gap-2">
            <div className="flex items-center gap-2 bg-ghost-green/10 border border-ghost-green/20 rounded-sm px-3 py-1.5 text-ghost-green text-[11px] tracking-[0.06em]">
              <span className="w-1.5 h-1.5 rounded-full bg-ghost-green animate-pulse-slow" />
              {shortAddress(wallet.address)}
            </div>
            <button
              onClick={disconnectWallet}
              className="bg-transparent border border-white/10 rounded-sm px-3 py-1.5 text-[10px] tracking-[0.08em] uppercase text-ghost-text-secondary cursor-pointer hover:bg-white/5 transition-colors"
            >
              Disconnect
            </button>
          </div>
        ) : (
          <button 
            onClick={connectWallet}
            className="bg-white/5 border border-white/10 rounded-sm px-4 py-2 text-ghost-text-primary text-[11px] tracking-[0.08em] uppercase cursor-pointer hover:bg-white/10 transition-colors"
          >
            Connect Wallet
          </button>
        )}
      </div>

      {/* Logo Header */}
      <div className="w-full max-w-[460px] flex justify-between items-center mb-8 relative z-10">
        <div className="flex items-center gap-2.5">
          <div className="text-ghost-gold">
            <Ghost size={22} fill="currentColor" />
          </div>
          <span className="font-serif text-[22px] font-light text-ghost-text-primary tracking-[-0.02em]">
            Ghost<span className="text-ghost-gold">Swap</span>
          </span>
        </div>
        <div className="flex items-center gap-1.5 text-[11px] text-ghost-text-muted tracking-[0.06em]">
          <Shield size={14} fill="currentColor" />
          {chainLabel}
        </div>
      </div>

      {uiError && (
        <div className="w-full max-w-[460px] mb-4 text-[11px] text-ghost-red bg-ghost-red/10 border border-ghost-red/25 rounded-sm px-3 py-2 relative z-10">
          {uiError}
        </div>
      )}

      {uiNotice && (
        <div
          className={`w-full max-w-[460px] mb-4 text-[11px] border rounded-sm px-3 py-2 relative z-10 ${
            uiNotice.tone === "success"
              ? "text-ghost-green bg-ghost-green/10 border-ghost-green/20"
              : "text-ghost-gold bg-ghost-gold/10 border-ghost-gold/25"
          }`}
        >
          {uiNotice.text}
        </div>
      )}

      {configIssues.length > 0 && (
        <div className="w-full max-w-[460px] mb-4 text-[11px] text-ghost-gold bg-ghost-gold/10 border border-ghost-gold/25 rounded-sm px-3 py-2 relative z-10">
          <div className="mb-1 text-[10px] uppercase tracking-[0.08em]">Configuration Required</div>
          {configIssues.map((issue) => (
            <div key={issue}>• {issue}</div>
          ))}
        </div>
      )}

      {/* Main Card */}
      <div className="w-full max-w-[460px] bg-ghost-card/95 border border-white/10 rounded-sm p-5 md:p-7 relative z-10 animate-fade-up shadow-[0_40px_80px_rgba(0,0,0,0.6),inset_0_1px_0_rgba(255,255,255,0.05)]">

        {/* Corner accents */}
        {[
          { t: 0, r: 0, bt: true, bl: true },
          { t: 0, l: 0, bt: true, br: true },
          { b: 0, r: 0, bb: true, bl: true },
          { b: 0, l: 0, bb: true, br: true }
        ].map((pos, i) => (
          <div key={i} className="absolute w-4 h-4 pointer-events-none" style={{
            top: pos.t === 0 ? 0 : 'auto',
            bottom: pos.b === 0 ? 0 : 'auto',
            right: pos.r === 0 ? 0 : 'auto',
            left: pos.l === 0 ? 0 : 'auto',
            borderTop: pos.bt ? '1px solid rgba(212,163,89,0.25)' : 'none',
            borderBottom: pos.bb ? '1px solid rgba(212,163,89,0.25)' : 'none',
            borderLeft: pos.bl ? '1px solid rgba(212,163,89,0.25)' : pos.br ? '1px solid rgba(212,163,89,0.25)' : 'none',
            borderRight: pos.rl ? '1px solid rgba(212,163,89,0.25)' : pos.rr ? '1px solid rgba(212,163,89,0.25)' : 'none',
          }} />
        ))}

        {swapState === SwapState.REVEALED && revealData ? (
          <RevealedView data={revealData} onReset={reset} />
        ) : (
          <>
            <div className="flex justify-between items-center mb-6">
              <span className="text-[11px] text-ghost-text-muted tracking-[0.1em] uppercase">
                Private Execution
              </span>
              <StatusBadge state={displaySwapState} />
            </div>

            {/* From field */}
            <div className="mb-1.5">
              <div className="text-[10px] text-ghost-text-muted mb-2 tracking-[0.08em] uppercase">From</div>
              <div className="bg-white/5 border border-white/10 rounded-sm p-3.5 flex items-center gap-3">
                <input
                  type="number"
                  value={amountIn}
                  onChange={e => setAmountIn(e.target.value)}
                  placeholder="0.00"
                  disabled={isBusy}
                  className="flex-1 bg-transparent border-none outline-none text-ghost-text-primary text-[24px] font-mono font-light w-0"
                />
                <TokenSelector selected={tokenIn} onSelect={setTokenIn} disabled={isBusy} />
              </div>
            </div>

            {/* Swap direction button */}
            <div className="flex justify-center my-2.5">
              <button
                onClick={() => { setTokenIn(tokenOut); setTokenOut(tokenIn); }}
                disabled={isBusy}
                className="bg-ghost-gold/10 border border-ghost-gold/20 rounded-full w-8 h-8 flex items-center justify-center cursor-pointer text-ghost-gold transition-colors duration-150 hover:bg-ghost-gold/20 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <ArrowDown size={14} />
              </button>
            </div>

            {/* To field */}
            <div className="mb-4">
              <div className="text-[10px] text-ghost-text-muted mb-2 tracking-[0.08em] uppercase">To</div>
              <div className="bg-white/5 border border-white/10 rounded-sm p-3.5 flex items-center gap-3">
                <div className="flex-1 text-[24px] text-ghost-text-dim font-light">—</div>
                <TokenSelector selected={tokenOut} onSelect={setTokenOut} disabled={isBusy} />
              </div>
            </div>

            {/* Min acceptable — encrypted field */}
            <div className="mb-5">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-1.5 text-[10px] text-ghost-text-muted tracking-[0.08em] uppercase">
                  <Lock size={12} fill="currentColor" />
                  Min Acceptable
                  <span className="bg-ghost-gold/10 border border-ghost-gold/25 rounded-sm px-1.5 py-[1px] text-[9px] text-ghost-gold tracking-[0.06em]">ENCRYPTED</span>
                </div>
                <span className="text-[9px] text-ghost-text-dim hidden sm:inline">never visible to solver</span>
              </div>

              <div className={`relative overflow-hidden border rounded-sm p-3.5 flex items-center gap-3 transition-all duration-300 ${isBusy ? 'bg-ghost-gold/5 border-ghost-gold/20' : 'bg-white/5 border-white/10'}`}>
                {isBusy && (
                  <div className="absolute inset-0 bg-gradient-to-r from-transparent via-ghost-gold/5 to-transparent bg-[length:200%_100%] animate-shimmer" />
                )}
                {isBusy ? (
                  <div className="flex-1 text-[15px] font-mono text-ghost-gold tracking-[0.05em] relative">
                    ████████████
                  </div>
                ) : (
                  <input
                    type="number"
                    value={minOut}
                    onChange={e => setMinOut(e.target.value)}
                    placeholder="3200.00"
                    disabled={isBusy}
                    className="flex-1 bg-transparent border-none outline-none text-ghost-text-primary text-[20px] font-mono font-light w-0 relative"
                  />
                )}
                <div className="flex items-center gap-1.5 text-ghost-gold relative">
                  <Lock size={14} fill="currentColor" />
                  <span className="text-[13px] font-medium">{tokenOut.symbol}</span>
                </div>
              </div>
            </div>

            {/* Action buttons */}
            {!isBusy && (
              <div className="flex flex-col gap-2.5">
                <button
                  onClick={submitSwap}
                  disabled={!canSwap}
                  className={`w-full p-4 rounded-sm text-[13px] font-mono font-medium tracking-[0.08em] uppercase transition-all duration-150 ${
                    canSwap
                      ? "bg-gradient-to-br from-ghost-gold to-ghost-gold-dark border-none text-ghost-card cursor-pointer hover:brightness-110 active:scale-[0.98]"
                      : "bg-white/5 border border-white/10 text-ghost-text-dim cursor-not-allowed"
                  }`}
                >
                  {!wallet
                    ? "Connect Wallet"
                    : wallet.chainId !== expectedChainId
                      ? `Switch To ${chainNameById(expectedChainId)}`
                      : !hasHookConfig
                        ? "Set VITE_POST_SETTLE_HOOK"
                        : !hasSwapConfig
                          ? "Set VITE_SWAP_ROUTER"
                          : !hasPoolConfig
                            ? "Set Pool Config"
                            : "Submit Private Swap"}
                </button>

                <button
                  type="button"
                  onClick={simulate}
                  className="relative z-10 w-full p-3 bg-transparent border border-white/10 rounded-sm text-[11px] text-ghost-text-secondary uppercase tracking-[0.08em] cursor-pointer pointer-events-auto hover:bg-white/5 hover:border-white/20 transition-colors"
                >
                  Sync Latest Swap
                </button>
              </div>
            )}

            {isBusy && (
              <button
                disabled
                className="w-full p-4 bg-ghost-gold/10 border border-ghost-gold/20 rounded-sm text-ghost-gold text-[13px] font-mono tracking-[0.08em] uppercase flex items-center justify-center gap-2"
              >
                <span className="animate-pulse-slow w-2 h-2 rounded-full bg-ghost-gold inline-block" />
                {swapState === SwapState.ENCRYPTING ? "Encrypting..." : swapState === SwapState.SUBMITTED ? "In Mempool..." : "Settling..."}
              </button>
            )}

            <PendingRevealPanel swap={trackedPendingSwap} currentBlock={currentBlock} onReveal={reveal} />

            {/* Compliance toggle */}
            {!isBusy && (
              <div className="mt-4">
                <button
                  onClick={() => setShowCompliance(!showCompliance)}
                  className="bg-transparent border-none text-[#4a4540] text-[11px] font-mono cursor-pointer flex items-center gap-1.5 tracking-[0.06em] p-0 hover:text-ghost-text-muted transition-colors"
                >
                  <Shield size={12} fill="currentColor" />
                  {showCompliance ? "Hide compliance settings" : "Add compliance party"}
                </button>

                {showCompliance && (
                  <div className="mt-2.5 animate-fade-up">
                    <input
                      type="text"
                      value={complianceAddr}
                      onChange={e => setComplianceAddr(e.target.value)}
                      placeholder="0x... compliance address"
                      className="w-full bg-white/5 border border-white/10 rounded-sm px-3.5 py-2.5 text-ghost-text-secondary text-[12px] font-mono outline-none"
                    />
                    <div className="text-[10px] text-ghost-text-dim mt-1.5">
                      This address is authorized in-hook to call reveal on your settled swaps.
                    </div>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>

      <div className="w-full max-w-[460px] relative z-10 hidden md:block">
        <MempoolComparison visible={showMempool} />
      </div>
      
      {/* Mobile mempool comparison drops to single column natively defined inside MempoolComparison component */}
      <div className="w-full max-w-[460px] relative z-10 block md:hidden">
        <MempoolComparison visible={showMempool} />
      </div>

      <div className="w-full max-w-[460px] relative z-10 transition-all duration-300">
        <TransactionHistory
          visible
          entries={visibleHistory}
          page={historyPage}
          totalPages={historyPages}
          onPrevPage={() => setHistoryPage((prev) => Math.max(0, prev - 1))}
          onNextPage={() => setHistoryPage((prev) => Math.min(historyPages - 1, prev + 1))}
          loading={historyLoading}
          onReveal={reveal}
        />
      </div>

      {/* Footer */}
      <div className="mt-8 text-[10px] text-ghost-text-dim tracking-[0.06em] text-center relative z-10">
        Built on Fhenix CoFHE · Uniswap v4 Hook · {chainLabel}
      </div>
    </div>
  );
}

function RevealedView({ data, onReset }) {
  return (
    <div className="animate-fade-up">
      <div className="flex items-center gap-2 mb-6 pb-5 border-b border-ghost-green/15">
        <div className="text-ghost-green">
          <Eye size={16} fill="currentColor" />
        </div>
        <span className="text-[11px] text-ghost-green tracking-[0.1em] uppercase">
          Trade Revealed
        </span>
      </div>

      {[
        { label: "You sent", value: `${data.amountIn} ${data.tokenIn}` },
        { label: "You received", value: `${data.amountOut} ${data.tokenOut}`, highlight: true },
        { label: "Execution price", value: `${data.executionPrice} ${data.tokenOut}/${data.tokenIn}` },
        { label: "Surplus captured", value: `+${data.surplus} ${data.tokenOut}`, positive: true },
        { label: "Block", value: `#${data.block}` },
        { label: "Tx hash", value: data.txHash },
      ].map(row => (
        <div key={row.label} className="flex justify-between items-center py-2.5 border-b border-white/5">
          <span className="text-[11px] text-ghost-text-muted font-mono">
            {row.label}
          </span>
          <span className={`text-[13px] font-mono ${row.positive ? "text-ghost-green" : row.highlight ? "text-ghost-text-primary font-medium" : "text-ghost-text-secondary font-light"}`}>
            {row.value}
          </span>
        </div>
      ))}

      <div className="mt-5 px-3.5 py-3 bg-ghost-gold/5 border border-ghost-gold/15 rounded-sm text-[11px] text-[#7a6a50] font-mono leading-[1.6]">
        Your <span className="text-ghost-gold">amountOutMinimum</span> was never visible to the solver. They filled at their honest best price.
      </div>

      <button
        onClick={onReset}
        className="w-full mt-5 p-3.5 bg-white/5 border border-white/10 rounded-sm text-[#7a7068] text-[12px] font-mono tracking-[0.08em] cursor-pointer uppercase hover:bg-white/10 transition-colors"
      >
        New Swap
      </button>
    </div>
  );
}
