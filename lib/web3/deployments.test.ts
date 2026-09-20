import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  LEGACY_HOOD_DEPLOYMENT,
  FROZEN_CANARY_V1_DEPLOYMENT,
  FROZEN_V2_DEPLOYMENT,
  getKnownDeploymentById,
} from "@/lib/web3/deployments";
import deploymentManifest from "@/deployments/robinhood-mainnet.json";

/**
 * The specific regression this guards against, in two successive forms:
 *
 * (1, historical) KNOWN_DEPLOYMENTS["canary-v1"] was once a second,
 * independent hardcoded address (still the 0x0000...0000 placeholder) -
 * completely disconnected from deployments/robinhood-mainnet.json, the
 * actual tracked source of truth.
 *
 * (2, the bug this file's own tests used to enforce as CORRECT and this
 * revision fixes) canary-v1 was then made to resolve dynamically through
 * getActiveDeployment() - which fixed (1), but only for as long as the
 * canary remained the app's own active deployment. The moment a future
 * deployment (V2) becomes active, that same dynamic resolution would
 * silently start returning V2's own chain/registry for canary-v1 requests
 * too - exactly the failure this deployment-scoping work exists to prevent,
 * since the canary TickerNFT's own immutable on-chain base URI
 * (https://clog.run/api/ticker-metadata/canary-v1/) can never be changed
 * to point anywhere else once minted.
 *
 * The fix: canary-v1 resolves to FROZEN_CANARY_V1_DEPLOYMENT forever.
 * V2 has now also been deployed and receives the same treatment through
 * FROZEN_V2_DEPLOYMENT. Neither historical deploymentId may follow the
 * active manifest dynamically once its immutable metadata URI is live.
 */
describe("canary-v1 deployment resolution (frozen, not dynamic)", () => {
  it("resolves to the canary's real, non-placeholder address", () => {
    const resolved = getKnownDeploymentById("canary-v1");
    expect(resolved).not.toBeNull();
    expect(resolved!.tickerRegistryAddress.toLowerCase()).not.toBe("0x0000000000000000000000000000000000000000");
  });

  it("resolves to exactly FROZEN_CANARY_V1_DEPLOYMENT - the fixed constant, not a fresh manifest read", () => {
    const resolved = getKnownDeploymentById("canary-v1");
    expect(resolved).toEqual(FROZEN_CANARY_V1_DEPLOYMENT);
  });

  it("remains the original canary after the active manifest moves to V2", () => {
    const resolved = getKnownDeploymentById("canary-v1");

    expect(resolved).toEqual({
      chainId: 4663,
      tickerRegistryAddress: "0xE631ed6E9E6FEAce145a0ab01cbd2BB947a4a2B2",
    });

    expect(resolved!.tickerRegistryAddress.toLowerCase()).not.toBe(
      deploymentManifest.contracts.tickerRegistry.toLowerCase()
    );
  });

  it("REGRESSION GUARD: does NOT track getActiveDeployment() - the exact bug this fix closes", () => {
    // If a future change reintroduces the old `() => getActiveDeployment()`
    // resolver for canary-v1, this test only fails once the active
    // deployment's env actually differs from the frozen canary values in
    // this specific test environment - which the "identical to a fresh
    // manifest read" test above already covers for the current, correct
    // state. This test instead proves the STRUCTURAL property directly: the
    // resolver is a fixed value, not a call to getActiveDeployment, by
    // reading this file's own source rather than relying on env divergence
    // to detect it.
    const source = readFileSync(path.join(process.cwd(), "lib/web3/deployments.ts"), "utf8");
    const canaryV1Line = source.split("\n").find((line) => line.trim().startsWith('"canary-v1":'));
    expect(canaryV1Line).toBeDefined();
    expect(canaryV1Line).not.toContain("getActiveDeployment");
    expect(canaryV1Line).toContain("FROZEN_CANARY_V1_DEPLOYMENT");
  });

  it("an unknown deploymentId still returns null, never falling back to the active deployment or any default", () => {
    expect(getKnownDeploymentById("not-a-real-deployment")).toBeNull();
  });
});

describe("v2 deployment resolution (frozen, not dynamic)", () => {
  it("resolves to exactly FROZEN_V2_DEPLOYMENT", () => {
    expect(getKnownDeploymentById("v2")).toEqual(
      FROZEN_V2_DEPLOYMENT
    );
  });

  it("matches the active V2 deployment manifest", () => {
    expect(FROZEN_V2_DEPLOYMENT.chainId).toBe(
      deploymentManifest.chainId
    );

    expect(
      FROZEN_V2_DEPLOYMENT.tickerRegistryAddress.toLowerCase()
    ).toBe(
      deploymentManifest.contracts.tickerRegistry.toLowerCase()
    );
  });

  it("REGRESSION GUARD: does not track getActiveDeployment()", () => {
    const source = readFileSync(
      path.join(process.cwd(), "lib/web3/deployments.ts"),
      "utf8"
    );

    const v2Line = source
      .split("\n")
      .find((line) => line.trim().startsWith("v2:"));

    expect(v2Line).toBeDefined();
    expect(v2Line).not.toContain("getActiveDeployment");
    expect(v2Line).toContain("FROZEN_V2_DEPLOYMENT");
  });
});

describe("legacy HOOD deployment - unaffected by the canary-v1 freeze", () => {
  it("remains the fixed, hardcoded constant it has always been - never derived from the manifest or active env", () => {
    expect(LEGACY_HOOD_DEPLOYMENT).toEqual({
      chainId: 4663,
      tickerRegistryAddress: "0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33",
    });
  });

  it("is never equal to canary-v1's resolution", () => {
    const canaryV1 = getKnownDeploymentById("canary-v1");
    expect(canaryV1!.tickerRegistryAddress.toLowerCase()).not.toBe(LEGACY_HOOD_DEPLOYMENT.tickerRegistryAddress.toLowerCase());
  });

  it("is never equal to v2's resolution", () => {
    const v2 = getKnownDeploymentById("v2");
    if (v2) {
      expect(v2.tickerRegistryAddress.toLowerCase()).not.toBe(LEGACY_HOOD_DEPLOYMENT.tickerRegistryAddress.toLowerCase());
    }
  });
});
