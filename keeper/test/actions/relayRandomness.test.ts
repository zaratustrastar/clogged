import { describe, it, expect } from "vitest";
import { relayFulfilledRandomness } from "../../src/actions/relayRandomness.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

describe("relayFulfilledRandomness decision path", () => {
  it("VRF fulfilled on Arbitrum, not yet relayed -> relays it", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients(
      {
        currentRoundId: 5n,
        getRound: { randomnessRequested: false, randomnessRequestId: 0n, settled: true }, // default fallback for rounds 1-3 - harmlessly skipped (settled=true short-circuits)
        "getRound:4": { randomnessRequested: true, randomnessRequestId: 77n, settled: false },
      },
      {
        "fulfilledRequests:77": [999n, true, false], // [randomWord, fulfilled, relayed]
      }
    );
    const lock = makeNoOpLock();

    const results = await relayFulfilledRandomness(config, clients, lock as never);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(arbitrumWriteContract).toHaveBeenCalledTimes(1);
    expect(arbitrumWriteContract.mock.calls[0][0]).toMatchObject({ functionName: "relayRandomness", args: [77n] });
  });

  it("VRF fulfilled but ALREADY relayed -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients(
      {
        currentRoundId: 5n,
        getRound: { randomnessRequested: false, randomnessRequestId: 0n, settled: true }, // default fallback for rounds 1-3 - harmlessly skipped (settled=true short-circuits)
        "getRound:4": { randomnessRequested: true, randomnessRequestId: 77n, settled: false },
      },
      {
        "fulfilledRequests:77": [999n, true, true], // already relayed
      }
    );
    const lock = makeNoOpLock();

    const results = await relayFulfilledRandomness(config, clients, lock as never);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("VRF NOT yet fulfilled -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients(
      {
        currentRoundId: 5n,
        getRound: { randomnessRequested: false, randomnessRequestId: 0n, settled: true }, // default fallback for rounds 1-3 - harmlessly skipped (settled=true short-circuits)
        "getRound:4": { randomnessRequested: true, randomnessRequestId: 77n, settled: false },
      },
      {
        "fulfilledRequests:77": [0n, false, false],
      }
    );
    const lock = makeNoOpLock();

    const results = await relayFulfilledRandomness(config, clients, lock as never);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("round already settled -> skips checking Arbitrum entirely (nothing left to relay)", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({
      currentRoundId: 5n,
      getRound: { randomnessRequested: false, randomnessRequestId: 0n, settled: true }, // default fallback for rounds 1-3
      "getRound:4": { randomnessRequested: true, randomnessRequestId: 77n, settled: true },
    });
    const lock = makeNoOpLock();

    const results = await relayFulfilledRandomness(config, clients, lock as never);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("a relay already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients(
      {
        currentRoundId: 5n,
        getRound: { randomnessRequested: false, randomnessRequestId: 0n, settled: true }, // default fallback for rounds 1-3 - harmlessly skipped (settled=true short-circuits)
        "getRound:4": { randomnessRequested: true, randomnessRequestId: 77n, settled: false },
      },
      {
        "fulfilledRequests:77": [999n, true, false],
      }
    );
    const lock = { isInFlight: async () => true, acquire: () => {}, release: () => {} };

    const results = await relayFulfilledRandomness(config, clients, lock as never);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });
});
