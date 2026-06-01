// Autonomous, headless reproduction of the GhostSwap encrypted swap — no browser/MetaMask.
// Encrypts via @cofhe/sdk (node), builds the EIP-712 intent + hookData, and staticCall-simulates
// swapRouter.swap to capture and fully decode the on-chain revert (incl. WrappedError/InvalidSigner).
//
// Usage:  PRIVATE_KEY=0x... node scripts/autoswap.mjs
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Encryptable } from "@cofhe/sdk";
import { createCofheClient, createCofheConfig } from "@cofhe/sdk/node";
import { chains } from "@cofhe/sdk/chains";
import { AbiCoder, Interface, JsonRpcProvider, getAddress, keccak256 } from "ethers";

const RPC = process.env.ARBITRUM_SEPOLIA_RPC || "https://sepolia-rollup.arbitrum.io/rpc";
const PK = process.env.PRIVATE_KEY;
if (!PK) throw new Error("PRIVATE_KEY env required");

const dep = JSON.parse(readFileSync(new URL("../../deployments/arbitrum-sepolia.json", import.meta.url)));
const HOOK = getAddress(dep.hook);
const ROUTER = getAddress(dep.swapRouter);
const TOKEN0 = getAddress(dep.token0);
const TOKEN1 = getAddress(dep.token1);
const FEE = 3000, TICK_SPACING = 60;

const viemChain = {
  id: 421614, name: "Arbitrum Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};

const account = privateKeyToAccount(PK.startsWith("0x") ? PK : `0x${PK}`);
console.log("Trader:", account.address);
console.log("Hook:", HOOK, "Router:", ROUTER);

const publicClient = createPublicClient({ chain: viemChain, transport: http(RPC) });
const walletClient = createWalletClient({ account, chain: viemChain, transport: http(RPC) });

// 1. Encrypt minOut via CoFHE
const cofheChain = { ...chains.arbSepolia };
const config = createCofheConfig({ supportedChains: [cofheChain] });
const client = createCofheClient(config);
console.log("Connecting CoFHE client...");
await client.connect(publicClient, walletClient);
// NOTE: permits are only needed for decryption; encryption does not require one (and the
// permit store has no storage backend in Node). Skip it for this headless repro.
console.log("Encrypting...");
const minOutRaw = 500000000000000000n; // 0.5e18
const POOL_MANAGER = getAddress(dep.poolManager);
// Bind the encrypted-input proof to the on-chain caller of verifyInput. In the v4-hook flow
// the hook's beforeSwap runs FHE.asEuint128, so msg.sender there = the PoolManager.
const [enc] = await client.encryptInputs([Encryptable.uint128(minOutRaw)]).setAccount(POOL_MANAGER).execute();
console.log("Bound encryption to PoolManager:", POOL_MANAGER);
console.log("Encrypted input:", {
  ctHash: enc.ctHash?.toString?.() ?? enc.ctHash,
  securityZone: enc.securityZone,
  utype: enc.utype,
  sigLen: (enc.signature || "").length,
});

// 2. poolId = keccak256(abi.encode(PoolKey))
const coder = AbiCoder.defaultAbiCoder();
const poolId = keccak256(coder.encode(
  ["tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)"],
  [[TOKEN0, TOKEN1, FEE, TICK_SPACING, HOOK]]
));
console.log("poolId:", poolId);

// 3. EIP-712 intent signature (unique nonce per run — the hook enforces single-use nonces)
const nonce = BigInt(Date.now());
const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);
const intentSig = await walletClient.signTypedData({
  account,
  domain: { name: "GhostSwapIntent", version: "1", chainId: 421614, verifyingContract: HOOK },
  types: {
    IntentAuthorization: [
      { name: "trader", type: "address" },
      { name: "sender", type: "address" },
      { name: "poolId", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "ctHash", type: "uint256" },
    ],
  },
  primaryType: "IntentAuthorization",
  message: { trader: account.address, sender: ROUTER, poolId, nonce, deadline, ctHash: BigInt(enc.ctHash) },
});

// 4. hookData
const hookData = coder.encode(
  ["tuple(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature)", "uint256", "address", "uint256", "bytes"],
  [[BigInt(enc.ctHash), Number(enc.securityZone ?? 0), Number(enc.utype ?? 6), enc.signature], nonce, account.address, deadline, intentSig]
);

// 5. staticCall swapRouter.swap and decode any revert
const ROUTER_ABI = [
  "function swap((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,(bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96) params,(bool takeClaims,bool settleUsingBurn) testSettings,bytes hookData) returns (int256)",
];
const ERR_ABI = [
  "error WrappedError(address target, bytes4 selector, bytes reason, bytes details)",
  "error InvalidSigner(address recovered, address expected)",
  "error InvalidSignature(address recovered, address expected)",
  "error InvalidEncryptedInput(uint8 got, uint8 expected)",
  "error SecurityZoneOutOfBounds(int32 value)",
  "error InvalidIntentSignature(address recovered, address expectedTrader)",
  "error InvalidHookData()",
  "error ACLNotAllowed(uint256 handle, address account)",
  "error NotAllowed(uint256 handle, address account)",
];
const erri = new Interface(ERR_ABI);
function unwrap(data, depth = 0) {
  if (typeof data !== "string" || !data.startsWith("0x") || data.length < 10 || depth > 6) return null;
  let p;
  try { p = erri.parseError(data); } catch { return { selector: data.slice(0, 10), raw: data }; }
  if (!p) return { selector: data.slice(0, 10), raw: data };
  if (p.name === "WrappedError") {
    console.log(`  ...wrapped by target=${p.args.target} selector=${p.args.selector}`);
    return unwrap(p.args.reason, depth + 1) || unwrap(p.args.details, depth + 1) || { name: "WrappedError", args: p.args };
  }
  return { name: p.name, args: p.args.map ? [...p.args] : p.args };
}

const { Wallet, Contract } = await import("ethers");
const provider = new JsonRpcProvider(RPC);
const signer = new Wallet(PK.startsWith("0x") ? PK : `0x${PK}`, provider);
const router = new Interface(ROUTER_ABI);
const swapArgs = [
  { currency0: TOKEN0, currency1: TOKEN1, fee: FEE, tickSpacing: TICK_SPACING, hooks: HOOK },
  { zeroForOne: true, amountSpecified: -1000000000000000000n, sqrtPriceLimitX96: 4295128740n },
  { takeClaims: false, settleUsingBurn: false },
  hookData,
];
const calldata = router.encodeFunctionData("swap", swapArgs);

// Approve token0 to the router (idempotent)
const erc20 = new Contract(TOKEN0, ["function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"], signer);
const allowance = await erc20.allowance(account.address, ROUTER);
if (allowance < 1000000000000000000n) {
  console.log("Approving token0 -> router...");
  const a = await erc20.approve(ROUTER, (1n << 256n) - 1n);
  await a.wait();
}

console.log("\nStep 1: staticCall (simulate)...");
try {
  await provider.call({ from: account.address, to: ROUTER, data: calldata, gasLimit: 30000000n });
  console.log("  staticCall SUCCEEDED");
} catch (e) {
  const data = e?.data || e?.info?.error?.data || e?.error?.data;
  console.log("  staticCall revert:", typeof data === "string" ? JSON.stringify(unwrap(data), (k, v) => (typeof v === "bigint" ? v.toString() : v)) : (e?.shortMessage || e?.message));
}

console.log("\nStep 2: broadcasting REAL swap tx...");
const { POST_SETTLE_REVEAL_ABI } = await import("../src/lib/postSettleRevealAbi.js");
const hook = new Contract(HOOK, POST_SETTLE_REVEAL_ABI, signer);
let swapId = 0n, settledAtBlock = 0n, decryptReadyBlock = 0n;
try {
  const tx = await signer.sendTransaction({ to: ROUTER, data: calldata, gasLimit: 5000000n });
  console.log("  tx hash:", tx.hash);
  const rcpt = await tx.wait();
  console.log("  STATUS:", rcpt.status === 1 ? "SUCCESS ✅" : "REVERTED ❌", "gasUsed:", rcpt.gasUsed.toString());
  // Recover swapId from the SettlementRecorded event
  for (const log of rcpt.logs) {
    if (log.address.toLowerCase() !== HOOK.toLowerCase()) continue;
    try {
      const parsed = hook.interface.parseLog({ topics: log.topics, data: log.data });
      if (parsed?.name === "SettlementRecorded") { swapId = parsed.args.swapId; settledAtBlock = parsed.args.settledAtBlock; }
    } catch {}
  }
  console.log("  swapId:", swapId.toString(), "settledAtBlock:", settledAtBlock.toString());
} catch (e) {
  console.log("  tx failed:", e?.shortMessage || e?.message);
  process.exit(1);
}

if (swapId === 0n) { console.log("Could not recover swapId; aborting reveal."); process.exit(1); }

// Read the on-chain decryptReadyBlock (note: this is an L1-paced block.number on Arbitrum,
// which differs from the L2 number returned by getBlockNumber(), so we don't compare directly).
const rec = await hook.getSettlementRecord(swapId);
decryptReadyBlock = rec.decryptReadyBlock;
const intent0 = await hook.getSwapIntent(swapId);
console.log("\nStep 3: pending reveal. decryptReadyBlock(L1):", decryptReadyBlock.toString(), "| state:", intent0.state.toString(), "(2=SettledPendingReveal)");

// Poll the reveal via staticCall — robust against the L1/L2 block-number duality.
console.log("  waiting for reveal window (the hook enforces a 15-block delay)...");
let ready = false;
for (let i = 0; i < 80; i++) {
  try {
    await hook.revealSwapDetails.staticCall(swapId);
    ready = true;
    break;
  } catch (e) {
    const data = e?.data || e?.info?.error?.data;
    let info = "still pending";
    try { const p = hook.interface.parseError(data); if (p) info = p.name === "RevealNotReady" ? `ready@${p.args.readyBlock} cur@${p.args.currentBlock}` : p.name; } catch {}
    process.stdout.write(`  ${info}            \r`);
    await new Promise((r) => setTimeout(r, 6000));
  }
}
if (!ready) { console.log("\n  reveal window did not open within timeout"); process.exit(1); }
console.log("\n  reveal window open ✅");

console.log("\nStep 4: revealSwapDetails...");
try {
  const rtx = await hook.revealSwapDetails(swapId);
  console.log("  reveal tx:", rtx.hash);
  const rr = await rtx.wait();
  console.log("  STATUS:", rr.status === 1 ? "SUCCESS ✅" : "REVERTED ❌");
  let revealed = null;
  for (const log of rr.logs) {
    if (log.address.toLowerCase() !== HOOK.toLowerCase()) continue;
    try { const p = hook.interface.parseLog({ topics: log.topics, data: log.data }); if (p?.name === "Revealed") revealed = p.args; } catch {}
  }
  const intent1 = await hook.getSwapIntent(swapId);
  console.log("  final state:", intent1.state.toString(), "(4=RevealedToAuthorized)");
  if (revealed) {
    console.log("  REVEALED trade details: delta0:", revealed.delta0?.toString(), "delta1:", revealed.delta1?.toString(), "amountSpecified:", revealed.amountSpecified?.toString());
  }
  console.log("\n=== END-TO-END COMPLETE: encrypt -> swap -> reveal ===");
} catch (e) {
  const data = e?.data || e?.info?.error?.data;
  console.log("  reveal failed:", e?.shortMessage || e?.message);
  if (typeof data === "string") console.log("  decoded:", JSON.stringify(unwrap(data), (k, v) => (typeof v === "bigint" ? v.toString() : v)));
}
process.exit(0);
