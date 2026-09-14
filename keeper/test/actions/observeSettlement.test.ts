import { describe, it, expect } from "vitest";
import { observeSettlement } from "../../src/actions/observeSettlement.js";
import { makeTestConfig, makeMockClients } from "../testHelpers.js";

describe("observeSettlement - purely observational, requires no keeper transaction", () => {
  it("never calls writeContract on either chain, regardless of round state", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients, writeContract, arbitrumWriteContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closeTime: 0n, drawSkipped: true, randomnessRequested: false, settled: false, winnerTokenId: 0n }, // default fallback for rounds 1-3
      "getRound:4": {
        closeTime: BigInt(nowSec - 100),
        drawSkipped: false,
        randomnessRequested: true,
        settled: false,
        winnerTokenId: 0n,
      },
    });

    await observeSettlement(config, clients);

    expect(writeContract).not.toHaveBeenCalled();
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("settled round -> reports info with the winner, no warning", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closeTime: 0n, drawSkipped: true, randomnessRequested: false, settled: false, winnerTokenId: 0n }, // default fallback for rounds 1-3
      "getRound:4": {
        closeTime: 0n,
        drawSkipped: false,
        randomnessRequested: true,
        settled: true,
        winnerTokenId: 42n,
      },
    });

    const results = await observeSettlement(config, clients);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("info");
    expect(relevant?.detail).toContain("42");
  });

  it("requested but unsettled for a long time -> reports a warning, not silent info", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closeTime: 0n, drawSkipped: true, randomnessRequested: false, settled: false, winnerTokenId: 0n }, // default fallback for rounds 1-3
      "getRound:4": {
        closeTime: BigInt(nowSec - 60 * 60), // 1 hour ago - well past the 30-minute warning threshold
        drawSkipped: false,
        randomnessRequested: true,
        settled: false,
        winnerTokenId: 0n,
      },
    });

    const results = await observeSettlement(config, clients);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("warn");
    expect(relevant?.detail).toMatch(/UNSETTLED/);
  });

  it("requested but unsettled only recently -> reports info, not a warning yet", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closeTime: 0n, drawSkipped: true, randomnessRequested: false, settled: false, winnerTokenId: 0n }, // default fallback for rounds 1-3
      "getRound:4": {
        closeTime: BigInt(nowSec - 60), // only 1 minute ago
        drawSkipped: false,
        randomnessRequested: true,
        settled: false,
        winnerTokenId: 0n,
      },
    });

    const results = await observeSettlement(config, clients);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("info");
  });

  it("drawSkipped round -> not reported at all (nothing to settle)", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closeTime: 0n, drawSkipped: true, randomnessRequested: false, settled: false, winnerTokenId: 0n }, // default fallback for rounds 1-3
      "getRound:4": {
        closeTime: 0n,
        drawSkipped: true,
        randomnessRequested: false,
        settled: false,
        winnerTokenId: 0n,
      },
    });

    const results = await observeSettlement(config, clients);
    expect(results.find((r) => r.detail.includes("round 4"))).toBeUndefined();
  });
});
