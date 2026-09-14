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
 * deploymentBlock, via KEEPER_MANIFEST_PATH - the REAL tracked manifest's
 * deploymentBlock is genuinely null as of this writing (the real value is
 * still pending a live on-chain verification run - see
 * scripts/verify-deployment.sh), so a test asserting the happy path must
 * not depend on that already being filled in. The one test that DOES use
 * the real manifest asserts exactly that current, accurate state.
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

  it("REAL manifest: throws on deploymentBlock, accurately reflecting its current unset state", () => {
    delete process.env.KEEPER_MANIFEST_PATH; // use the real, tracked manifest
    expect(() => loadConfig([])).toThrow(/deploymentBlock/);
  });
});
