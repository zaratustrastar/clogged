import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";

/**
 * v4TradingMode is a real three-state decision, not a boolean, specifically
 * so "flag enabled but misconfigured" can never silently behave like "flag
 * off" - see lib/web3/env.ts's own docs for why. Each test re-imports env.ts
 * fresh (vi.resetModules() + dynamic import) after setting process.env
 * directly, since the module computes its exported values once at import
 * time from whatever NEXT_PUBLIC_* vars are present then - a normal static
 * top-level import would only ever see whichever env snapshot happened to
 * be active for the first test that imported it.
 */
describe("v4TradingMode", () => {
  const V4_KEYS = [
    "NEXT_PUBLIC_V4_TRADING_ENABLED",
    "NEXT_PUBLIC_V4_POOL_MANAGER_ADDRESS",
    "NEXT_PUBLIC_UNIVERSAL_ROUTER_ADDRESS",
    "NEXT_PUBLIC_PERMIT2_ADDRESS",
    "NEXT_PUBLIC_CLOG_V4_HOOK_ADDRESS",
  ] as const;
  const originalValues: Record<string, string | undefined> = {};

  beforeEach(() => {
    for (const key of V4_KEYS) originalValues[key] = process.env[key];
  });

  afterEach(() => {
    for (const key of V4_KEYS) {
      if (originalValues[key] === undefined) delete process.env[key];
      else process.env[key] = originalValues[key];
    }
    vi.resetModules();
  });

  async function freshV4TradingMode() {
    vi.resetModules();
    const mod = await import("./env");
    return mod.v4TradingMode;
  }

  it('is "direct" when the flag is unset', async () => {
    delete process.env.NEXT_PUBLIC_V4_TRADING_ENABLED;
    for (const key of V4_KEYS.slice(1)) delete process.env[key];
    expect(await freshV4TradingMode()).toBe("direct");
  });

  it('is "direct" when the flag is explicitly "false", even with every address present', async () => {
    process.env.NEXT_PUBLIC_V4_TRADING_ENABLED = "false";
    process.env.NEXT_PUBLIC_V4_POOL_MANAGER_ADDRESS = "0x1000000000000000000000000000000000000001";
    process.env.NEXT_PUBLIC_UNIVERSAL_ROUTER_ADDRESS = "0x1000000000000000000000000000000000000002";
    process.env.NEXT_PUBLIC_PERMIT2_ADDRESS = "0x1000000000000000000000000000000000000003";
    process.env.NEXT_PUBLIC_CLOG_V4_HOOK_ADDRESS = "0x1000000000000000000000000000000000000004";
    expect(await freshV4TradingMode()).toBe("direct");
  });

  it('is "v4" when the flag is "true" and every required address is present', async () => {
    process.env.NEXT_PUBLIC_V4_TRADING_ENABLED = "true";
    process.env.NEXT_PUBLIC_V4_POOL_MANAGER_ADDRESS = "0x1000000000000000000000000000000000000001";
    process.env.NEXT_PUBLIC_UNIVERSAL_ROUTER_ADDRESS = "0x1000000000000000000000000000000000000002";
    process.env.NEXT_PUBLIC_PERMIT2_ADDRESS = "0x1000000000000000000000000000000000000003";
    process.env.NEXT_PUBLIC_CLOG_V4_HOOK_ADDRESS = "0x1000000000000000000000000000000000000004";
    expect(await freshV4TradingMode()).toBe("v4");
  });

  it('is "misconfigured" - NEVER "direct" - when the flag is "true" but one address is missing', async () => {
    process.env.NEXT_PUBLIC_V4_TRADING_ENABLED = "true";
    process.env.NEXT_PUBLIC_V4_POOL_MANAGER_ADDRESS = "0x1000000000000000000000000000000000000001";
    process.env.NEXT_PUBLIC_UNIVERSAL_ROUTER_ADDRESS = "0x1000000000000000000000000000000000000002";
    process.env.NEXT_PUBLIC_PERMIT2_ADDRESS = "0x1000000000000000000000000000000000000003";
    delete process.env.NEXT_PUBLIC_CLOG_V4_HOOK_ADDRESS; // the one missing piece
    const mode = await freshV4TradingMode();
    expect(mode).toBe("misconfigured");
    expect(mode).not.toBe("direct");
  });

  it('is "misconfigured" when the flag is "true" and every address is missing', async () => {
    process.env.NEXT_PUBLIC_V4_TRADING_ENABLED = "true";
    for (const key of V4_KEYS.slice(1)) delete process.env[key];
    expect(await freshV4TradingMode()).toBe("misconfigured");
  });
});
