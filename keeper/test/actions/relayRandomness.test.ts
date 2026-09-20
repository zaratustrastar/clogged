import { describe, it, expect } from "vitest";
import { relayFulfilledRandomness } from "../../src/actions/relayRandomness.js";
import { RoundLedger } from "../../src/roundLedger.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

describe("relayFulfilledRandomness decision path (event-driven ledger, no fixed lookback)", () => {
  it("VRF fulfilled on Arbitrum, not yet relayed -> relays it", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients(
      {},
      { "fulfilledRequests:77": [999n, true, false] } // [randomWord, fulfilled, relayed]
    );
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);

    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(arbitrumWriteContract).toHaveBeenCalledTimes(1);
    expect(arbitrumWriteContract.mock.calls[0][0]).toMatchObject({ functionName: "relayRandomness", args: [77n] });
  });

  it("VRF fulfilled but ALREADY relayed -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({}, { "fulfilledRequests:77": [999n, true, true] });
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("VRF NOT yet fulfilled -> does nothing", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({}, { "fulfilledRequests:77": [0n, false, false] });
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("round already settled -> removed from the ledger entirely, never checked on Arbitrum at all", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({});
    const lock = makeNoOpLock();
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
      settledRounds: [4n],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);
    expect(results.every((r) => !r.acted)).toBe(true);
    expect(clients.arbitrumPublic.readContract).not.toHaveBeenCalled();
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("a relay already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({}, { "fulfilledRequests:77": [999n, true, false] });
    const lock = { isInFlight: async () => true, acquire: () => {}, release: () => {} };
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);
    expect(results.some((r) => r.detail.includes("already in flight"))).toBe(true);
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("REQUIREMENT: an old fulfilled-but-unrelayed request (from long before the keeper was last online) is found", async () => {
    const config = makeTestConfig();
    const { clients, arbitrumWriteContract } = makeMockClients({}, { "fulfilledRequests:12": [555n, true, false] });
    const lock = makeNoOpLock();
    // requestId 12, round 2 - both "old" relative to any fixed lookback
    // window; the ledger has no age concept, only real requested-and-
    // unsettled state.
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 2n, requestId: 12n }],
    });

    const results = await relayFulfilledRandomness(config, clients, lock as never, ledger);
    const acted = results.filter((r) => r.acted);
    expect(acted).toHaveLength(1);
    expect(arbitrumWriteContract.mock.calls[0][0]).toMatchObject({ functionName: "relayRandomness", args: [12n] });
  });

  it("REQUIREMENT: restart reconstructs outstanding relay work correctly", async () => {
    const config = makeTestConfig();
    const { clients: clientsRun1, arbitrumWriteContract: write1 } = makeMockClients({}, { "fulfilledRequests:77": [999n, true, false] });
    const ledgerRun1 = RoundLedger.withState(clientsRun1.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });
    await relayFulfilledRandomness(config, clientsRun1, makeNoOpLock() as never, ledgerRun1);
    expect(write1).toHaveBeenCalledTimes(1);

    // A brand new ledger instance (simulating a restart) reconstructed
    // from the same real event history must find the same outstanding
    // relay work - it was never actually relayed on-chain between "runs"
    // in this test, exactly as it wouldn't be after a real crash.
    const { clients: clientsRun2, arbitrumWriteContract: write2 } = makeMockClients({}, { "fulfilledRequests:77": [999n, true, false] });
    const ledgerRun2 = RoundLedger.withState(clientsRun2.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });
    const results = await relayFulfilledRandomness(config, clientsRun2, makeNoOpLock() as never, ledgerRun2);
    expect(results.filter((r) => r.acted)).toHaveLength(1);
    expect(write2.mock.calls[0][0]).toMatchObject({ functionName: "relayRandomness", args: [77n] });
  });
});
