import { describe, it, expect } from "vitest";
import { BaseError, ContractFunctionRevertedError } from "viem";
import { translateContractError } from "@/lib/hooks/useProtocolActions";

const EXPIRY_MESSAGE = "Transaction took too long and expired — try again.";

/** Builds a real viem error chain shaped like what a genuine BondingCurveClog
 * "expired" revert actually produces: an outer BaseError-derived error whose
 * .cause is a ContractFunctionRevertedError with .reason set to the exact
 * revert string the contract used. */
function makeStructuredRevert(reason: string): Error {
  const revertError = new ContractFunctionRevertedError({
    abi: [],
    functionName: "buy",
  });
  revertError.reason = reason;
  return new BaseError("boom", { cause: revertError });
}

describe("translateContractError - expiry misclassification fix", () => {
  it("translates a genuine, structured 'expired' revert reason to the expiry message", () => {
    const err = makeStructuredRevert("expired");
    expect(translateContractError(err)).toBe(EXPIRY_MESSAGE);
  });

  it("does not treat every structured revert reason as an expiry - only the exact 'expired' string", () => {
    const err = makeStructuredRevert("exceeds available token inventory");
    expect(translateContractError(err)).not.toBe(EXPIRY_MESSAGE);
  });

  it("THE ORIGINAL BUG: a plain error whose text merely mentions the word 'deadline' (viem's own ABI parameter echo, present for every buy/sell call regardless of what reverted) is no longer misclassified as an expiry", () => {
    const err = new Error(
      'The contract function "buy" reverted.\n\nContract Call:\n  function:  buy(uint256 minTotalTokensOut, uint256 deadline)\n  args:      (198000000000000000000000, 1735689000)'
    );
    expect(translateContractError(err)).not.toBe(EXPIRY_MESSAGE);
  });

  it("a real inventory-exceeded revert is still correctly classified even though the same diagnostic text mentions 'deadline'", () => {
    const err = new Error(
      'The contract function "buy" reverted with the following reason:\nexceeds available token inventory\n\nContract Call:\n  function:  buy(uint256 minTotalTokensOut, uint256 deadline)'
    );
    expect(translateContractError(err)).toBe("That amount is too large for the current curve depth — try a smaller amount.");
  });

  it("a genuinely unrecognized error never falls back to the expiry message merely by coincidence", () => {
    const err = new Error("Some unrelated RPC error with no revert reason at all");
    expect(translateContractError(err)).not.toBe(EXPIRY_MESSAGE);
  });
});
