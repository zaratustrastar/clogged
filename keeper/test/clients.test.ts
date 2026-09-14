import { describe, it, expect } from "vitest";
import { createClients } from "../src/clients.js";
import { makeTestConfig } from "./testHelpers.js";

describe("createClients - dry-run creates no wallet signer (Part: --dry-run must not require KEEPER_PRIVATE_KEY)", () => {
  it("REQUIREMENT: with keeperPrivateKey undefined (dry-run), no signer is created - keeperAddress falls back to the optional public config.keeperAddress", () => {
    const config = makeTestConfig({ dryRun: true, keeperPrivateKey: undefined, keeperAddress: "0x1234500000000000000000000000000000000a" });
    const clients = createClients(config);
    expect(clients.keeperAddress).toBe("0x1234500000000000000000000000000000000a");
  });

  it("keeperAddress is undefined when neither keeperPrivateKey nor config.keeperAddress is set", () => {
    const config = makeTestConfig({ dryRun: true, keeperPrivateKey: undefined, keeperAddress: undefined });
    const clients = createClients(config);
    expect(clients.keeperAddress).toBeUndefined();
  });

  it("REQUIREMENT: dry-run's robinhoodWallet cannot invoke writeContract - calling it throws immediately rather than sending anything", () => {
    const config = makeTestConfig({ dryRun: true, keeperPrivateKey: undefined });
    const clients = createClients(config);
    expect(() => clients.robinhoodWallet.writeContract({} as never)).toThrow(/writeContract called/);
  });

  it("REQUIREMENT: dry-run's arbitrumWallet cannot invoke writeContract either", () => {
    const config = makeTestConfig({ dryRun: true, keeperPrivateKey: undefined });
    const clients = createClients(config);
    expect(() => clients.arbitrumWallet.writeContract({} as never)).toThrow(/writeContract called/);
  });

  it("normal mode (a real keeperPrivateKey present) creates a real signer with an actual account - not the dry-run no-signer stub", () => {
    const config = makeTestConfig({ dryRun: false, keeperPrivateKey: ("0x" + "2".repeat(64)) as `0x${string}` });
    const clients = createClients(config);
    expect(clients.keeperAddress).toMatch(/^0x[0-9a-fA-F]{40}$/);
    // The real wallet client has an `account` property (its own signer);
    // the dry-run no-signer stub deliberately does not - this is the
    // direct, structural proof a real signer was built here, without
    // actually invoking writeContract (which would return a real pending
    // promise against an unreachable test RPC URL, not a useful signal).
    expect((clients.robinhoodWallet as unknown as { account?: unknown }).account).toBeDefined();
  });
});
