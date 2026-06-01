import { Encryptable, isCofheError } from "@cofhe/sdk";
import { createCofheClient, createCofheConfig } from "@cofhe/sdk/web";
import { chains } from "@cofhe/sdk/chains";
import { createPublicClient, createWalletClient, custom } from "viem";

// NOTE: the @cofhe/sdk chains export key is `arbSepolia` (not `arbitrumSepolia`).
const SUPPORTED_CHAIN = chains.arbSepolia;

// Chain the CoFHE coprocessor / SDK is bound to. Encryption only works here.
// Defensive fallback so a future SDK rename can't crash module load / blank the UI.
export const SUPPORTED_CHAIN_ID = SUPPORTED_CHAIN?.id ?? 421614;

function normalizeEncryptedInput(input) {
  if (!input || input.ctHash == null || input.signature == null) {
    throw new Error("CoFHE encryption returned an invalid encrypted input.");
  }

  const securityZone = input.securityZone == null ? 0 : Number(input.securityZone);
  const utype = input.utype == null ? 6 : Number(input.utype);

  return {
    ctHash: BigInt(input.ctHash),
    securityZone,
    utype,
    signature: input.signature,
  };
}

export async function encryptMinOut({ minOutRaw, chainId, traderAddress, ethereumProvider, bindAddress }) {
  if (!ethereumProvider) {
    throw new Error("No injected wallet provider found.");
  }

  if (chainId !== SUPPORTED_CHAIN.id) {
    throw new Error(
      `@cofhe/sdk encryption is configured for Arbitrum Sepolia (${SUPPORTED_CHAIN.id}). Connected chain: ${chainId}.`
    );
  }

  const config = createCofheConfig({
    supportedChains: [SUPPORTED_CHAIN],
  });

  const client = createCofheClient(config);

  const transport = custom(ethereumProvider);
  const publicClient = createPublicClient({
    chain: SUPPORTED_CHAIN,
    transport,
  });

  const walletClient = createWalletClient({
    account: traderAddress,
    chain: SUPPORTED_CHAIN,
    transport,
  });

  await client.connect(publicClient, walletClient);
  await client.permits.getOrCreateSelfPermit();

  // Bind the encrypted-input proof to the on-chain caller of CoFHE verifyInput. In the v4-hook
  // flow that is the PoolManager (msg.sender inside the hook's beforeSwap), NOT the trader wallet.
  // Without this the on-chain verifier rejects the input with InvalidSigner.
  let builder = client.encryptInputs([Encryptable.uint128(minOutRaw)]);
  if (bindAddress) {
    builder = builder.setAccount(bindAddress);
  }
  const [encryptedInput] = await builder.execute();

  return normalizeEncryptedInput(encryptedInput);
}

export function mapCofheError(error) {
  if (isCofheError(error)) {
    return `${error.code}: ${error.message}`;
  }

  return null;
}
