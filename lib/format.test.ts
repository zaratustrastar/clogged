import { describe, it, expect } from "vitest";
import { formatEthPrecise, formatEth } from "./format";

describe("formatEthPrecise - small non-zero reward formatting", () => {
  it("REQUIREMENT: a small real reward (0.000007975624735752 ETH, from a real RewardVault.previewClaim of 7975624735752 wei) shows real, non-zero digits - never '0.0000 ETH'", () => {
    const result = formatEthPrecise(0.000007975624735752);
    expect(result).not.toBe("0.0000 ETH");
    expect(result).not.toMatch(/^0\.0000\s*ETH$/);
    // Shows the real leading significant digits (798), not just zeros.
    expect(result).toBe("0.00000798 ETH");
  });

  it("a value at the formatEth threshold (>= 0.0001) still uses ordinary 4-decimal formatting", () => {
    expect(formatEthPrecise(0.1234)).toBe("0.1234 ETH");
    expect(formatEthPrecise(1)).toBe("1 ETH");
  });

  it("a value just below the ordinary threshold still shows its real digits, not a placeholder", () => {
    const result = formatEthPrecise(0.00012345);
    expect(result).not.toContain("<");
    expect(result).toBe("0.0001 ETH");
  });

  it("an extremely small nonzero value (e.g. near 1 wei) never exceeds a sane maximum decimal count", () => {
    const result = formatEthPrecise(0.000000000000000001); // 1 wei
    expect(result).not.toBe("0.0000 ETH");
    const decimalsShown = result.split(".")[1]?.split(" ")[0].length ?? 0;
    expect(decimalsShown).toBeLessThanOrEqual(18);
  });

  it("zero is still shown as a plain zero, not a misleading tiny-decimal expansion", () => {
    expect(formatEthPrecise(0)).toBe("0 ETH");
  });
});

describe("formatEth - unchanged for its existing callers (coarser display, e.g. jackpot/market-cap tickers)", () => {
  it("still collapses a very small value to the existing placeholder - this behavior is intentionally NOT changed here, only formatEthPrecise is new", () => {
    expect(formatEth(0.000007975624735752)).toBe("<0.0001 ETH");
  });

  it("ordinary values are unaffected", () => {
    expect(formatEth(0.1234)).toBe("0.1234 ETH");
    expect(formatEth(0)).toBe("0 ETH");
  });
});
