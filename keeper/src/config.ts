import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { Address, Hex } from "viem";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * Contract addresses and chain id come from the SAME tracked deployment
 * manifest the frontend uses (deployments/robinhood-mainnet.json at the
 * repo root) - one source of truth, never duplicated or hand-copied here.
 * If that manifest is wrong, both the frontend and the keeper are wrong
 * together, and fixing it fixes both - there is no second place to update.
 *
 * Everything else the keeper needs (the keeper's own private key, RPC
 * URLs) is env-only, on purpose - see README.md's "Security assumptions"
 * section for why none of this belongs in the tracked manifest.
 */
interface DeploymentManifest {
  chainId: number;
  deploymentBlock: number | null;
  contracts: {
    tickerRegistry: Address;
    tickerNFT: Address;
    eligibilityRegistry: Address;
    roundManager: Address;
    rewardVault: Address;
  };
  ["$notReadByFrontend"]: {
    chainlinkRandomnessProvider: Address;
    arbitrumVrfWrapper: Address;
    arbitrumVrfSubscriptionId: string;
    arbitrumVrfKeyHash: Hex;
  };
}

function loadManifest(): DeploymentManifest {
  // KEEPER_MANIFEST_PATH override exists purely for test isolation (see
  // test/config.test.ts) - normal operation always uses the real, tracked
  // manifest at the repo root.
  const manifestPath = process.env.KEEPER_MANIFEST_PATH || path.join(__dirname, "../../deployments/robinhood-mainnet.json");
  const raw = readFileSync(manifestPath, "utf8");
  return JSON.parse(raw) as DeploymentManifest;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `Missing required environment variable ${name}. See keeper/README.md and keeper/.env.example - ` +
        `the keeper refuses to start with an incomplete configuration rather than guess or fall back to ` +
        `a default that could point it at the wrong wallet or network.`
    );
  }
  return value;
}

export interface KeeperConfig {
  dryRun: boolean;

  robinhoodRpcUrl: string;
  arbitrumRpcUrl: string;

  /** The dedicated keeper EOA's private key. NEVER the deployer, Safe, or
   * governance wallet - see README.md's "Security assumptions" section for
   * why: every action this keeper takes is permissionless by contract
   * design (verified directly against source - see README.md), so the
   * keeper key needs no elevated permission whatsoever. Giving it one
   * would violate least-privilege for no operational benefit and create a
   * real loss risk this design specifically avoids. */
  keeperPrivateKey: Hex;

  chainId: number;
  deploymentBlock: bigint;
  tickerRegistry: Address;
  tickerNFT: Address;
  eligibilityRegistry: Address;
  roundManager: Address;
  rewardVault: Address;
  chainlinkRandomnessProvider: Address;
  arbitrumVrfWrapper: Address;
  arbitrumVrfSubscriptionId: bigint;
  arbitrumVrfKeyHash: Hex;

  /** How often the keeper loop runs, in milliseconds. */
  pollIntervalMs: number;

  /** Maximum number of blocks requested in a single eth_getLogs call, for
   * every historical/incremental log scan (TokenWatchlist, RoundLedger).
   * Real RPC providers vary in what block range/log count they'll accept
   * in one call, and this keeper has no way to know a given provider's
   * own limit in advance - see blockRangeChunker.ts for the shared
   * chunking this bounds. Conservative default deliberately well under
   * common provider caps (many enforce something in the 2,000-10,000
   * block range); lower it further via KEEPER_LOG_CHUNK_BLOCKS if a
   * specific provider needs it. */
  logChunkSizeBlocks: bigint;

  /** Below this ETH balance (in wei), fundingHealth logs a WARNING for the
   * given address - see README.md's "no automatic funding in v1" note:
   * this NEVER triggers an automatic transfer, only a log line an operator
   * (or their own external alerting on that log) is expected to act on. */
  lowBalanceWarningThresholdWei: bigint;

  /** Where the keeper's own idempotency/lock state file lives - see lock.ts. */
  lockFilePath: string;
}

export function loadConfig(argv: string[] = process.argv.slice(2)): KeeperConfig {
  const dryRun = argv.includes("--dry-run");

  // Cheapest, cheapest-to-diagnose check first: a missing key is always
  // wrong regardless of manifest state, so report it before spending any
  // effort validating the manifest.
  const keeperPrivateKey = requireEnv("KEEPER_PRIVATE_KEY") as Hex;

  const manifest = loadManifest();

  // The manifest's own $notReadByFrontend addresses must be real (not the
  // zero-address placeholder some manifest entries may still carry) before
  // the keeper can safely start - refusing to start on a placeholder is
  // safer than silently polling a zero address forever.
  const zero = "0x0000000000000000000000000000000000000000";
  for (const [label, addr] of Object.entries({
    tickerRegistry: manifest.contracts.tickerRegistry,
    tickerNFT: manifest.contracts.tickerNFT,
    eligibilityRegistry: manifest.contracts.eligibilityRegistry,
    roundManager: manifest.contracts.roundManager,
    rewardVault: manifest.contracts.rewardVault,
    chainlinkRandomnessProvider: manifest["$notReadByFrontend"].chainlinkRandomnessProvider,
    arbitrumVrfWrapper: manifest["$notReadByFrontend"].arbitrumVrfWrapper,
  })) {
    if (!addr || addr.toLowerCase() === zero) {
      throw new Error(
        `deployments/robinhood-mainnet.json's ${label} is missing or still the zero-address placeholder. ` +
          `The keeper refuses to start against an unverified/incomplete manifest - run scripts/verify-deployment.sh ` +
          `and fill in every address first.`
      );
    }
  }
  if (manifest.deploymentBlock == null) {
    throw new Error(
      `deployments/robinhood-mainnet.json's deploymentBlock is not yet set. The keeper refuses to start until it ` +
        `is - see scripts/verify-deployment.sh's own output for the real, verified value.`
    );
  }

  return {
    dryRun,
    robinhoodRpcUrl: process.env.ROBINHOOD_RPC_URL || "https://rpc.mainnet.chain.robinhood.com",
    arbitrumRpcUrl: process.env.ARBITRUM_RPC_URL || "https://arb1.arbitrum.io/rpc",
    keeperPrivateKey,
    chainId: manifest.chainId,
    deploymentBlock: BigInt(manifest.deploymentBlock as number),
    tickerRegistry: manifest.contracts.tickerRegistry,
    tickerNFT: manifest.contracts.tickerNFT,
    eligibilityRegistry: manifest.contracts.eligibilityRegistry,
    roundManager: manifest.contracts.roundManager,
    rewardVault: manifest.contracts.rewardVault,
    chainlinkRandomnessProvider: manifest["$notReadByFrontend"].chainlinkRandomnessProvider,
    arbitrumVrfWrapper: manifest["$notReadByFrontend"].arbitrumVrfWrapper,
    arbitrumVrfSubscriptionId: BigInt(manifest["$notReadByFrontend"].arbitrumVrfSubscriptionId),
    arbitrumVrfKeyHash: manifest["$notReadByFrontend"].arbitrumVrfKeyHash,
    pollIntervalMs: Number(process.env.KEEPER_POLL_INTERVAL_MS || 30_000),
    logChunkSizeBlocks: BigInt(process.env.KEEPER_LOG_CHUNK_BLOCKS || "2000"),
    lowBalanceWarningThresholdWei: BigInt(process.env.KEEPER_LOW_BALANCE_WARNING_WEI || "5000000000000000"), // 0.005 ETH default
    lockFilePath: process.env.KEEPER_LOCK_FILE || path.join(__dirname, "../.keeper-lock.json"),
  };
}
