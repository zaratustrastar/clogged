import { describe, it, expect } from "vitest";
import { computeSellApprovalState } from "@/lib/hooks/useProtocolActions";

describe("computeSellApprovalState - sell approval gating", () => {
  it("A. allowance < requested sell amount -> approval required", () => {
    const result = computeSellApprovalState({
      allowance: 0n,
      sellAmountWei: 10_000_000000000000000000n, // 10,000 tokens
    });
    expect(result.needsApproval).toBe(true);
    expect(result.hasEnoughAllowance).toBe(false);
    expect(result.checkingAllowance).toBe(false);
  });

  it("A (partial allowance). an allowance that covers some but not all of the requested amount still requires approval", () => {
    const result = computeSellApprovalState({
      allowance: 5_000_000000000000000000n, // 5,000 tokens approved
      sellAmountWei: 10_000_000000000000000000n, // but 10,000 requested
    });
    expect(result.needsApproval).toBe(true);
    expect(result.hasEnoughAllowance).toBe(false);
  });

  it("B. allowance >= requested amount -> sell allowed without approval", () => {
    const result = computeSellApprovalState({
      allowance: 198978_001876459213675822n, // the real production balance from the bug report
      sellAmountWei: 10_000_000000000000000000n, // selling 10,000 of it
    });
    expect(result.needsApproval).toBe(false);
    expect(result.hasEnoughAllowance).toBe(true);
    expect(result.checkingAllowance).toBe(false);
  });

  it("B (exact match). an allowance exactly equal to the requested amount is sufficient (>=, not >)", () => {
    const amount = 10_000_000000000000000000n;
    const result = computeSellApprovalState({ allowance: amount, sellAmountWei: amount });
    expect(result.hasEnoughAllowance).toBe(true);
    expect(result.needsApproval).toBe(false);
  });

  it("reports checkingAllowance while the allowance read hasn't resolved yet at all - never conflated with a resolved allowance of zero", () => {
    const result = computeSellApprovalState({ allowance: null, sellAmountWei: 10_000_000000000000000000n });
    expect(result.checkingAllowance).toBe(true);
    expect(result.needsApproval).toBe(false); // not yet known - never assume approval is needed before checking
    expect(result.hasEnoughAllowance).toBe(false);
  });

  it("never requires approval or reports checking for an empty/zero amount (nothing to sell yet)", () => {
    const zero = computeSellApprovalState({ allowance: 0n, sellAmountWei: 0n });
    expect(zero.needsApproval).toBe(false);
    expect(zero.checkingAllowance).toBe(false);

    const none = computeSellApprovalState({ allowance: 0n, sellAmountWei: null });
    expect(none.needsApproval).toBe(false);
    expect(none.checkingAllowance).toBe(false);
  });
});
