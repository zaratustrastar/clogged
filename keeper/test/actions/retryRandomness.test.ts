import { describe, it, expect } from "vitest";
import { retryFailedRandomness } from "../../src/actions/retryRandomness.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

describe("retryFailedRandomness decision path", () => {
  it("closed round, drawable, randomness NOT yet requested -> retries it", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closed: true, drawSkipped: true, randomnessRequested: false, settled: false }, // default fallback for rounds 1-3 in the lookback window - harmlessly skipped
      "getRound:4": { closed: true, drawSkipped: false, randomnessRequested: false, settled: false },
    });
    const lock = makeNoOpLock();

    const results = await retryFailedRandomness(config, clients, lock as never);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(writeContract).toHaveBeenCalledTimes(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "requestRandomnessForRound", args: [4n] });
  });

  it("randomness already requested for the round -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closed: true, drawSkipped: true, randomnessRequested: false, settled: false }, // default fallback for rounds 1-3 in the lookback window - harmlessly skipped
      "getRound:4": { closed: true, drawSkipped: false, randomnessRequested: true, settled: false },
    });
    const lock = makeNoOpLock();

    const results = await retryFailedRandomness(config, clients, lock as never);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("round already settled -> does nothing (nothing left to retry)", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closed: true, drawSkipped: true, randomnessRequested: false, settled: false }, // default fallback for rounds 1-3 in the lookback window - harmlessly skipped
      "getRound:4": { closed: true, drawSkipped: false, randomnessRequested: true, settled: true },
    });
    const lock = makeNoOpLock();

    const results = await retryFailedRandomness(config, clients, lock as never);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("round drawSkipped (fewer than MIN_DRAW_CANDIDATES) -> does nothing, never requests randomness for it", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closed: true, drawSkipped: true, randomnessRequested: false, settled: false }, // default fallback for rounds 1-3 in the lookback window - harmlessly skipped
      "getRound:4": { closed: true, drawSkipped: true, randomnessRequested: false, settled: false },
    });
    const lock = makeNoOpLock();

    const results = await retryFailedRandomness(config, clients, lock as never);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("a retry already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { closed: true, drawSkipped: true, randomnessRequested: false, settled: false }, // default fallback for rounds 1-3 in the lookback window - harmlessly skipped
      "getRound:4": { closed: true, drawSkipped: false, randomnessRequested: false, settled: false },
    });
    const lock = { isInFlight: async () => true, acquire: () => {}, release: () => {} };

    const results = await retryFailedRandomness(config, clients, lock as never);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });
});
