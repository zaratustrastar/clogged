import { vi } from "vitest";
import type { Clients } from "../src/clients.js";
import type { KeeperConfig } from "../src/config.js";

/** A minimal, deterministic KeeperConfig for decision-path tests - not
 * loaded from any real manifest or env var, since these tests exercise
 * pure decision logic against mocked chain responses, never real RPC. */
export function makeTestConfig(overrides: Partial<KeeperConfig> = {}): KeeperConfig {
  return {
    dryRun: false,
    robinhoodRpcUrl: "http://localhost:0",
    arbitrumRpcUrl: "http://localhost:0",
    keeperPrivateKey: ("0x" + "1".repeat(64)) as `0x${string}`,
    chainId: 4663,
    deploymentBlock: 1000n,
    tickerRegistry: "0x1000000000000000000000000000000000000a",
    tickerNFT: "0x1000000000000000000000000000000000000b",
    eligibilityRegistry: "0x1000000000000000000000000000000000000c",
    roundManager: "0x1000000000000000000000000000000000000d",
    rewardVault: "0x1000000000000000000000000000000000000e",
    chainlinkRandomnessProvider: "0x1000000000000000000000000000000000000f",
    arbitrumVrfWrapper: "0x10000000000000000000000000000000000010",
    arbitrumVrfSubscriptionId: 12345n,
    arbitrumVrfKeyHash: ("0x" + "ab".repeat(32)) as `0x${string}`,
    pollIntervalMs: 30_000,
    lowBalanceWarningThresholdWei: 5_000_000_000_000_000n,
    lockFilePath: "/tmp/clog-keeper-test-lock.json",
    ...overrides,
  };
}

/** A read-response table keyed by contract function name - each test
 * supplies exactly the functions its scenario needs; anything unlisted
 * throws loudly rather than silently returning undefined, so a test that
 * forgets to mock a value it actually needs fails clearly instead of
 * producing a confusing downstream assertion failure. */
export type ReadResponses = Record<string, unknown>;

export function makeMockClients(robinhoodReads: ReadResponses, arbitrumReads: ReadResponses = {}): { clients: Clients; writeContract: ReturnType<typeof vi.fn>; arbitrumWriteContract: ReturnType<typeof vi.fn> } {
  const writeContract = vi.fn(async () => "0xabc0000000000000000000000000000000000000000000000000000000000001" as `0x${string}`);
  const arbitrumWriteContract = vi.fn(async () => "0xdef0000000000000000000000000000000000000000000000000000000000002" as `0x${string}`);

  function makeReadContract(table: ReadResponses) {
    return vi.fn(async ({ functionName, args }: { functionName: string; args?: unknown[] }) => {
      const key = args && args.length > 0 ? `${functionName}:${args.map(String).join(",")}` : functionName;
      if (key in table) return table[key];
      if (functionName in table) return table[functionName];
      throw new Error(`makeMockClients: no mocked response for ${key} - add it to the test's read table`);
    });
  }

  const account = { address: "0x9999999999999999999999999999999999999a" as `0x${string}` };

  const clients = {
    robinhoodPublic: {
      readContract: makeReadContract(robinhoodReads),
      getTransactionReceipt: vi.fn(async () => null),
      getBlockNumber: vi.fn(async () => 2000n),
      getContractEvents: vi.fn(async () => []),
    },
    robinhoodWallet: { writeContract, chain: { id: 4663 }, account },
    arbitrumPublic: { readContract: makeReadContract(arbitrumReads), getTransactionReceipt: vi.fn(async () => null) },
    arbitrumWallet: { writeContract: arbitrumWriteContract, chain: { id: 42161 }, account },
    keeperAddress: account.address,
  } as unknown as Clients;

  return { clients, writeContract, arbitrumWriteContract };
}

/** A lock that reports nothing is ever in flight and records acquisitions -
 * for tests that don't specifically exercise locking behavior itself
 * (that's lock.test.ts's job). */
export function makeNoOpLock() {
  const acquired: { key: string; txHash: string; chain: string }[] = [];
  return {
    isInFlight: vi.fn(async () => false),
    acquire: vi.fn((key: string, txHash: `0x${string}`, chain: "robinhood" | "arbitrum") => {
      acquired.push({ key, txHash, chain });
    }),
    release: vi.fn(),
    acquired,
  };
}
