import { createPublicClient, createWalletClient, http, defineChain, type Chain, type PublicClient, type WalletClient, type HttpTransport } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { arbitrum } from "viem/chains";
import type { KeeperConfig } from "./config.js";

/** Robinhood Chain Mainnet - not in viem's built-in chain list, defined
 * here directly from the same values the frontend's own lib/web3/chain.ts
 * uses (chain id 4663, native ETH). */
export function robinhoodChain(config: KeeperConfig): Chain {
  return defineChain({
    id: config.chainId,
    name: "Robinhood Chain",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [config.robinhoodRpcUrl] } },
  });
}

export interface Clients {
  robinhoodPublic: PublicClient<HttpTransport, Chain>;
  robinhoodWallet: WalletClient<HttpTransport, Chain, PrivateKeyAccount>;
  arbitrumPublic: PublicClient<HttpTransport, Chain>;
  arbitrumWallet: WalletClient<HttpTransport, Chain, PrivateKeyAccount>;
  /** undefined only in --dry-run mode with neither KEEPER_PRIVATE_KEY nor
   * KEEPER_ADDRESS set - see fundingHealth.ts for how it handles this. */
  keeperAddress: `0x${string}` | undefined;
}

/** Thrown immediately if anything ever calls .writeContract on the
 * no-signer stub below - the structural guarantee behind "dry-run cannot
 * invoke writeContract": even a bug that skips an action's own
 * `if (config.dryRun)` check hits this loud, specific error rather than
 * a generic "Cannot read properties of undefined" or, worse, silently
 * succeeding. */
function noSignerStub(chainLabel: string): WalletClient<HttpTransport, Chain, PrivateKeyAccount> {
  return {
    writeContract: () => {
      throw new Error(
        `writeContract called on ${chainLabel} with no keeper private key configured - this must be structurally ` +
          `impossible in dry-run mode. If you are seeing this, an action's own dry-run check was bypassed - see clients.ts.`
      );
    },
  } as unknown as WalletClient<HttpTransport, Chain, PrivateKeyAccount>;
}

export function createClients(config: KeeperConfig): Clients {
  const rhChain = robinhoodChain(config);
  const robinhoodPublic = createPublicClient({ chain: rhChain, transport: http(config.robinhoodRpcUrl) });
  const arbitrumPublic = createPublicClient({ chain: arbitrum, transport: http(config.arbitrumRpcUrl) });

  // A single dedicated keeper EOA, derived from KEEPER_PRIVATE_KEY, used as
  // the signer on BOTH chains - never the deployer, Safe, or governance
  // wallet (see config.ts's own docs and README.md's security assumptions
  // section for why this is safe: every action this account ever signs is
  // permissionless by contract design, so it needs no elevated permission
  // on either chain).
  //
  // Only created when a real private key is present. In --dry-run mode
  // without one (the normal dry-run case - see config.ts), NO signer is
  // ever constructed at all: robinhoodWallet/arbitrumWallet are the
  // no-signer stub above (writeContract structurally throws if ever
  // called), and keeperAddress falls back to the optional, PUBLIC
  // KEEPER_ADDRESS if the operator supplied one, or undefined otherwise.
  if (config.keeperPrivateKey) {
    const account = privateKeyToAccount(config.keeperPrivateKey);
    const robinhoodWallet = createWalletClient({ account, chain: rhChain, transport: http(config.robinhoodRpcUrl) });
    const arbitrumWallet = createWalletClient({ account, chain: arbitrum, transport: http(config.arbitrumRpcUrl) });
    return { robinhoodPublic, robinhoodWallet, arbitrumPublic, arbitrumWallet, keeperAddress: account.address };
  }

  return {
    robinhoodPublic,
    robinhoodWallet: noSignerStub("Robinhood Chain"),
    arbitrumPublic,
    arbitrumWallet: noSignerStub("Arbitrum One"),
    keeperAddress: config.keeperAddress,
  };
}
