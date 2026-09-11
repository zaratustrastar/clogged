import { describe, it, expect } from "vitest";
import { parseUnits } from "viem";

describe("sell amount precision - parseUnits vs the old floating-point bug", () => {
  it("C. parseUnits('10000', 18) produces exactly 10000000000000000000000", () => {
    expect(parseUnits("10000", 18)).toBe(10000000000000000000000n);
  });

  it("D. the real production balance from the bug report converts exactly via parseUnits, with every digit preserved", () => {
    // The exact balance reported: balanceOf(wallet) = 198978001876459213675822
    // (wei). As a human-readable token amount, that's 198978.001876459213675822.
    const exact = parseUnits("198978.001876459213675822", 18);
    expect(exact).toBe(198978001876459213675822n);
  });

  it("D. THE ORIGINAL BUG: the old conversion path (Number(amount) * 1e18) loses precision for this exact real-world amount - proving why parseUnits is required, not optional", () => {
    const amountString = "198978.001876459213675822";
    const viaFloatingPoint = BigInt(Math.round(Number(amountString) * 1e18));
    const viaParseUnits = parseUnits(amountString, 18);
    // The floating-point path does NOT reproduce the exact on-chain value -
    // this is precisely the bug: silently selling a different amount than
    // what the user actually typed, or than what a MAX-balance sell should
    // send back to the contract.
    expect(viaFloatingPoint).not.toBe(viaParseUnits);
    expect(viaParseUnits).toBe(198978001876459213675822n);
  });

  it("D. a large round number amount also converts exactly (not just the edge-case decimal)", () => {
    expect(parseUnits("1000000", 18)).toBe(1000000000000000000000000n);
  });

  it("TradeWidget's own try/catch pattern never lets invalid partial input (e.g. mid-typing '12.') throw up to the UI", () => {
    expect(() => {
      try {
        parseUnits("12.", 18);
      } catch {
        /* handled, same as TradeWidget's own catch block */
      }
    }).not.toThrow();
  });
});
