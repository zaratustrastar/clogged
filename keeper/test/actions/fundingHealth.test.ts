import { describe, it, expect } from "vitest";
import { checkFundingHealth } from "../../src/actions/fundingHealth.js";
import { makeTestConfig, makeMockClients } from "../testHelpers.js";

// The real, tracked manifest now has a real arbitrumVrfCoordinator (see
// deployments/robinhood-mainnet.json) - fundingHealth.ts reads it directly
// from that file (not via KeeperConfig), so these tests mock the VRF
// subscription read it will genuinely attempt, rather than assuming it's
// skipped.
const VRF_SUBSCRIPTION_READS = {
  getSubscription: [1_000_000_000_000_000_000n, 0n, 0n, "0x0000000000000000000000000000000000000000", []],
};

describe("checkFundingHealth - keeper-EOA balance check skip (Part: dry-run has no signer)", () => {
  it("REQUIREMENT: with no keeper address available at all (dry-run, no KEEPER_PRIVATE_KEY, no KEEPER_ADDRESS), the keeper-EOA checks are skipped, but Provider/Wrapper/VRF checks still run", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({}, VRF_SUBSCRIPTION_READS);
    (clients as unknown as { keeperAddress: undefined }).keeperAddress = undefined;

    const results = await checkFundingHealth(config, clients);

    expect(results.some((r) => r.detail.includes("Keeper EOA balance checks skipped"))).toBe(true);
    expect(results.some((r) => r.detail.includes("ChainlinkRandomnessProvider"))).toBe(true);
    expect(results.some((r) => r.detail.includes("VRFWrapperOnArbitrum"))).toBe(true);
    expect(results.some((r) => r.detail.includes("VRF subscription"))).toBe(true);
    expect(results.some((r) => r.detail.includes("Keeper EOA") && !r.detail.includes("skipped"))).toBe(false);
  });

  it("with a keeper address available (real key, or the optional public KEEPER_ADDRESS in dry-run), the keeper-EOA checks run normally", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({}, VRF_SUBSCRIPTION_READS);
    // makeMockClients' default keeperAddress is already set - the normal case.

    const results = await checkFundingHealth(config, clients);

    expect(results.some((r) => r.detail.includes("Keeper EOA") && r.detail.includes("Robinhood Chain"))).toBe(true);
    expect(results.some((r) => r.detail.includes("Keeper EOA") && r.detail.includes("Arbitrum One"))).toBe(true);
    expect(results.some((r) => r.detail.includes("Keeper EOA balance checks skipped"))).toBe(false);
  });

  it("never calls writeContract on either chain - purely read-only regardless of keeper address availability", async () => {
    const config = makeTestConfig();
    const { clients, writeContract, arbitrumWriteContract } = makeMockClients({}, VRF_SUBSCRIPTION_READS);
    (clients as unknown as { keeperAddress: undefined }).keeperAddress = undefined;

    await checkFundingHealth(config, clients);

    expect(writeContract).not.toHaveBeenCalled();
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });
});
