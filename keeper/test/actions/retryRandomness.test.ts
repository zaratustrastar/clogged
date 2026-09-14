import { describe, it, expect } from "vitest";
import { retryFailedRandomness } from "../../src/actions/retryRandomness.js";
import { RoundLedger } from "../../src/roundLedger.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

describe("retryFailedRandomness decision path (event-driven ledger, no fixed lookback)", () => {
  it("closed round, drawable, randomness NOT yet requested -> retries it", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(writeContract).toHaveBeenCalledTimes(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "requestRandomnessForRound", args: [4n] });
  });

  it("randomness already requested for the round -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);

    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("round already settled -> does nothing (removed from the ledger entirely, not merely skipped)", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
      settledRounds: [4n],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("round drawSkipped (fewer than MIN_DRAW_CANDIDATES) -> does nothing, never requests randomness for it", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: true }],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("a retry already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = { isInFlight: async () => true, acquire: () => {}, release: () => {} };
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("REQUIREMENT: keeper offline for far more than 20 rounds still finds an old failed randomness request", async () => {
    const config = makeTestConfig();
    const { clients, writeContract } = makeMockClients({});
    const lock = makeNoOpLock();
    // Round 3 closed 500 rounds ago (relative to a "current" round far past
    // any fixed 20-round window) and was never successfully requested -
    // the ledger has no age concept at all, only real event-derived state.
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 3n, drawSkipped: false }],
    });

    const results = await retryFailedRandomness(config, clients, lock as never, ledger);
    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "requestRandomnessForRound", args: [3n] });
  });

  it("REQUIREMENT: restart reconstructs outstanding work correctly - a fresh ledger built from the same event history finds the same due round", async () => {
    const config = makeTestConfig();
    const { clients: clientsRun1, writeContract: writeContract1 } = makeMockClients({});
    const ledgerRun1 = RoundLedger.withState(clientsRun1.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
    });
    await retryFailedRandomness(config, clientsRun1, makeNoOpLock() as never, ledgerRun1);
    expect(writeContract1).toHaveBeenCalledTimes(1);

    // Simulates a full process restart: a BRAND NEW ledger instance,
    // reconstructed from the identical real event history (the round was
    // never actually resolved between "runs" here, exactly as it wouldn't
    // be after a real crash) - it must find the exact same outstanding
    // round, not lose track of it.
    const { clients: clientsRun2, writeContract: writeContract2 } = makeMockClients({});
    const ledgerRun2 = RoundLedger.withState(clientsRun2.robinhoodPublic, config.roundManager, {
      closedRounds: [{ roundId: 4n, drawSkipped: false }],
    });
    const results = await retryFailedRandomness(config, clientsRun2, makeNoOpLock() as never, ledgerRun2);
    expect(results.filter((r) => r.acted)).toHaveLength(1);
    expect(writeContract2.mock.calls[0][0]).toMatchObject({ functionName: "requestRandomnessForRound", args: [4n] });
  });
});
