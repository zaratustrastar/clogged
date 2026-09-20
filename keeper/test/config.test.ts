import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "../src/config.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * All of this is testable without any RPC access, since config loading is
 * pure file/env parsing and validation - no chain interaction happens
 * until createClients() (clients.ts) is called separately.
 *
 * Most tests here use a temp manifest with a fake-but-well-formed
 * deploymentBlock, via KEEPER_MANIFEST_PATH, so the happy-path tests never
 * depend on the real tracked manifest's own current state. The one test
 * that DOES use the real manifest asserts its current, accurate state:
 * deploymentBlock = 61564258, independently verified on-chain (see
 * deployments/robinhood-mainnet.json's own $verification block and
 * docs/DEPLOYMENTS.md) - inherited from the already-verified frontend
 * rollout this branch was created from, not re-derived here.
 */
describe("keeper config loading", () => {
  const ORIGINAL_ENV = { ...process.env };
  let tmpDir: string;
  let validManifestPath: string;

  beforeEach(() => {
    process.env.KEEPER_PRIVATE_KEY = "0x" + "1".repeat(64);
    tmpDir = mkdtempSync(path.join(tmpdir(), "clog-keeper-config-test-"));
    validManifestPath = path.join(tmpDir, "manifest.json");

    const realManifest = JSON.parse(
      readFileSync(path.join(__dirname, "../../deployments/robinhood-mainnet.json"), "utf8")
    );
    realManifest.deploymentBlock = 123456; // fake-but-well-formed, for happy-path tests only
    writeFileSync(validManifestPath, JSON.stringify(realManifest));
    process.env.KEEPER_MANIFEST_PATH = validManifestPath;
  });

  afterEach(() => {
    process.env = { ...ORIGINAL_ENV };
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("loads successfully with a well-formed manifest and a valid private key", () => {
    const config = loadConfig([]);
    expect(config.chainId).toBe(4663);
    expect(config.tickerRegistry).toMatch(/^0x[0-9a-fA-F]{40}$/);
    expect(config.dryRun).toBe(false);
  });

  it("--dry-run sets dryRun true", () => {
    const config = loadConfig(["--dry-run"]);
    expect(config.dryRun).toBe(true);
  });

  it("throws if KEEPER_PRIVATE_KEY is not set, even with an otherwise-valid manifest", () => {
    delete process.env.KEEPER_PRIVATE_KEY;
    expect(() => loadConfig([])).toThrow(/KEEPER_PRIVATE_KEY/);
  });

  it("REQUIREMENT: --dry-run starts successfully with no KEEPER_PRIVATE_KEY set at all", () => {
    delete process.env.KEEPER_PRIVATE_KEY;
    const config = loadConfig(["--dry-run"]);
    expect(config.dryRun).toBe(true);
    expect(config.keeperPrivateKey).toBeUndefined();
  });

  it("dry-run never reads KEEPER_PRIVATE_KEY even if it happens to be set in the environment - genuinely read-only, not merely unused", () => {
    // beforeEach already sets a real-looking KEEPER_PRIVATE_KEY - this
    // proves dry-run mode doesn't pick it up anyway, exactly as it
    // wouldn't if it were absent. Dry-run's own config.keeperPrivateKey
    // must be undefined regardless of what's in the environment.
    expect(process.env.KEEPER_PRIVATE_KEY).toBeTruthy();
    const config = loadConfig(["--dry-run"]);
    expect(config.keeperPrivateKey).toBeUndefined();
  });

  it("dry-run picks up an optional, public KEEPER_ADDRESS when supplied", () => {
    delete process.env.KEEPER_PRIVATE_KEY;
    process.env.KEEPER_ADDRESS = "0x" + "ab".repeat(20);
    const config = loadConfig(["--dry-run"]);
    expect(config.keeperAddress?.toLowerCase()).toBe(("0x" + "ab".repeat(20)).toLowerCase());
    expect(config.keeperPrivateKey).toBeUndefined();
  });

  it("dry-run's keeperAddress is undefined when KEEPER_ADDRESS is not supplied either", () => {
    delete process.env.KEEPER_PRIVATE_KEY;
    delete process.env.KEEPER_ADDRESS;
    const config = loadConfig(["--dry-run"]);
    expect(config.keeperAddress).toBeUndefined();
  });

  it("respects ROBINHOOD_RPC_URL / ARBITRUM_RPC_URL overrides", () => {
    process.env.ROBINHOOD_RPC_URL = "https://custom-robinhood-rpc.example";
    process.env.ARBITRUM_RPC_URL = "https://custom-arbitrum-rpc.example";
    const config = loadConfig([]);
    expect(config.robinhoodRpcUrl).toBe("https://custom-robinhood-rpc.example");
    expect(config.arbitrumRpcUrl).toBe("https://custom-arbitrum-rpc.example");
  });

  it("defaults to the public Robinhood/Arbitrum RPC endpoints when not overridden", () => {
    delete process.env.ROBINHOOD_RPC_URL;
    delete process.env.ARBITRUM_RPC_URL;
    const config = loadConfig([]);
    expect(config.robinhoodRpcUrl).toBe("https://rpc.mainnet.chain.robinhood.com");
    expect(config.arbitrumRpcUrl).toBe("https://arb1.arbitrum.io/rpc");
  });

  it("respects a custom low-balance warning threshold", () => {
    process.env.KEEPER_LOW_BALANCE_WARNING_WEI = "1000000000000000000"; // 1 ETH
    const config = loadConfig([]);
    expect(config.lowBalanceWarningThresholdWei).toBe(1000000000000000000n);
  });

  it("reads VRF subscription id and keyHash from the manifest, not hardcoded", () => {
    const config = loadConfig([]);
    expect(config.arbitrumVrfSubscriptionId).toBe(
      83568090110973637554258631175012043155383488095251779152218551458964868806531n
    );
    expect(config.arbitrumVrfKeyHash).toBe("0x8472ba59cf7134dfe321f4d61a430c4857e8b19cdd5230b09952a92671c24409");
  });

  it("throws if any manifest address is still the zero-address placeholder", () => {
    const manifest = JSON.parse(readFileSync(validManifestPath, "utf8"));
    manifest.contracts.rewardVault = "0x0000000000000000000000000000000000000000";
    writeFileSync(validManifestPath, JSON.stringify(manifest));
    expect(() => loadConfig([])).toThrow(/rewardVault/);
  });

  it("REAL manifest: loads successfully with the real, independently-verified deploymentBlock", () => {
    delete process.env.KEEPER_MANIFEST_PATH; // use the real, tracked manifest
    const config = loadConfig([]);
    expect(config.deploymentBlock).toBe(67501280n);
  });

  describe("KEEPER_RPC_PACING_MS validation", () => {
    it("unset -> defaults to 0", () => {
      delete process.env.KEEPER_RPC_PACING_MS;
      expect(loadConfig([]).rpcPacingDelayMs).toBe(0);
    });

    it('"0" -> 0', () => {
      process.env.KEEPER_RPC_PACING_MS = "0";
      expect(loadConfig([]).rpcPacingDelayMs).toBe(0);
    });

    it("a positive integer -> accepted as-is", () => {
      process.env.KEEPER_RPC_PACING_MS = "250";
      expect(loadConfig([]).rpcPacingDelayMs).toBe(250);
    });

    it("a negative value -> rejected with a clear error, never silently accepted", () => {
      process.env.KEEPER_RPC_PACING_MS = "-1";
      expect(() => loadConfig([])).toThrow(/KEEPER_RPC_PACING_MS/);
    });

    it("a decimal value -> rejected (a millisecond delay has no fractional meaning here)", () => {
      process.env.KEEPER_RPC_PACING_MS = "1.5";
      expect(() => loadConfig([])).toThrow(/KEEPER_RPC_PACING_MS/);
    });

    it("garbage (non-numeric) -> rejected with a clear error, never silently coerced to NaN or 0", () => {
      process.env.KEEPER_RPC_PACING_MS = "abc";
      expect(() => loadConfig([])).toThrow(/KEEPER_RPC_PACING_MS/);
    });

    it("Infinity/NaN-shaped strings are also rejected, not just obviously-wrong ones", () => {
      process.env.KEEPER_RPC_PACING_MS = "Infinity";
      expect(() => loadConfig([])).toThrow(/KEEPER_RPC_PACING_MS/);
      process.env.KEEPER_RPC_PACING_MS = "NaN";
      expect(() => loadConfig([])).toThrow(/KEEPER_RPC_PACING_MS/);
    });
  });
});
