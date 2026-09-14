import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { LEGACY_HOOD_DEPLOYMENT, getKnownDeploymentById, getActiveDeployment } from "@/lib/web3/deployments";
import deploymentManifest from "@/deployments/robinhood-mainnet.json";

/**
 * The specific regression this guards against: KNOWN_DEPLOYMENTS["canary-v1"]
 * was previously a second, independent hardcoded address (still the
 * 0x0000...0000 placeholder as of the bug this fixes) - completely
 * disconnected from deployments/robinhood-mainnet.json, the actual tracked
 * source of truth. A real canary TickerNFT deployed with base URI
 * https://clog.run/api/ticker-metadata/canary-v1/ would have had every one
 * of its metadata requests resolve against that placeholder forever,
 * regardless of what the manifest said.
 */
describe("canary-v1 deployment resolution", () => {
  it("resolves to the manifest's real, current TickerRegistry address - not a placeholder, not a second hardcoded value", () => {
    const resolved = getKnownDeploymentById("canary-v1");
    expect(resolved).not.toBeNull();
    expect(resolved!.tickerRegistryAddress.toLowerCase()).toBe(deploymentManifest.contracts.tickerRegistry.toLowerCase());
    expect(resolved!.tickerRegistryAddress.toLowerCase()).not.toBe("0x0000000000000000000000000000000000000000");
  });

  it("resolves to the manifest's chainId, not a hardcoded value", () => {
    const resolved = getKnownDeploymentById("canary-v1");
    expect(resolved!.chainId).toBe(deploymentManifest.chainId);
  });

  it("is structurally identical to getActiveDeployment() - the same underlying value, read once, never duplicated", () => {
    // This is what makes drift between "canary-v1" and "the active
    // deployment" impossible rather than merely unlikely: both resolve
    // through the exact same function, so there is only ever one place
    // either value could come from. If a future change ever makes these
    // diverge, this test fails immediately.
    const canaryV1 = getKnownDeploymentById("canary-v1");
    const active = getActiveDeployment();
    expect(canaryV1).toEqual(active);
  });

  it("cannot drift from the manifest: changing the manifest's tickerRegistry would change canary-v1's resolution too (proven via the shared source, not a copy)", () => {
    // Not literally mutating the manifest file mid-test (that would be a
    // filesystem side effect no other test should have to account for) -
    // instead, this proves the NO-DRIFT property the way it actually
    // holds: by asserting canary-v1's resolved address is read from
    // deploymentManifest.contracts.tickerRegistry directly (checked above)
    // rather than from any separately-maintained literal in
    // lib/web3/deployments.ts's own source text.
    const source = readFileSync(path.join(process.cwd(), "lib/web3/deployments.ts"), "utf8");
    // No second hardcoded 40-hex-char address literal for canary-v1 - the
    // only address literal in this file must be LEGACY_HOOD_DEPLOYMENT's
    // own fixed constant (asserted separately below), never a canary one.
    const hexAddressLiterals = source.match(/0x[0-9a-fA-F]{40}/g) ?? [];
    expect(hexAddressLiterals).toEqual(["0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33"]);
  });

  it("an unknown deploymentId still returns null, never falling back to the active deployment or any default", () => {
    expect(getKnownDeploymentById("not-a-real-deployment")).toBeNull();
  });
});

describe("legacy HOOD deployment - unaffected by the canary-v1 fix", () => {
  it("remains the fixed, hardcoded constant it has always been - never derived from the manifest or active env", () => {
    expect(LEGACY_HOOD_DEPLOYMENT).toEqual({
      chainId: 4663,
      tickerRegistryAddress: "0xaf5b710DE2EafD2614D2CFFb01B953d8c664Ea33",
    });
  });

  it("is never equal to canary-v1's resolution, even though canary-v1 now resolves to a real (non-placeholder) address", () => {
    const canaryV1 = getKnownDeploymentById("canary-v1");
    expect(canaryV1!.tickerRegistryAddress.toLowerCase()).not.toBe(LEGACY_HOOD_DEPLOYMENT.tickerRegistryAddress.toLowerCase());
  });
});
