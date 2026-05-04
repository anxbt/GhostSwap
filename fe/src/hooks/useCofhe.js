import { Encryptable, isCofheError } from "@cofhe/sdk";
import { createCofheClient, createCofheConfig } from "@cofhe/sdk/web";
import { chains } from "@cofhe/sdk/chains";
import { createPublicClient, createWalletClient, custom } from "viem";

const SUPPORTED_CHAIN = chains.arbitrumSepolia;

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

export async function encryptMinOut({ minOutRaw, chainId, traderAddress, ethereumProvider }) {
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

  const [encryptedInput] = await client
    .encryptInputs([Encryptable.uint128(minOutRaw)])
    .execute();

  return normalizeEncryptedInput(encryptedInput);
}

export function mapCofheError(error) {
  if (isCofheError(error)) {
    return `${error.code}: ${error.message}`;
  }

  return null;
}
