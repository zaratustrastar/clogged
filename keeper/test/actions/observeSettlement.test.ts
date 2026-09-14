import { describe, it, expect } from "vitest";
import { observeSettlement } from "../../src/actions/observeSettlement.js";
import { RoundLedger } from "../../src/roundLedger.js";
import { makeTestConfig, makeMockClients } from "../testHelpers.js";

describe("observeSettlement - purely observational, requires no keeper transaction, no fixed lookback", () => {
  it("never calls writeContract on either chain, regardless of round state", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients, writeContract, arbitrumWriteContract } = makeMockClients({
      "getRound:4": { closeTime: BigInt(nowSec - 100), settled: false, winnerTokenId: 0n },
    });
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    await observeSettlement(config, clients, ledger);

    expect(writeContract).not.toHaveBeenCalled();
    expect(arbitrumWriteContract).not.toHaveBeenCalled();
  });

  it("settled round -> reports info with the winner, no warning", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({
      "getRound:4": { closeTime: 0n, settled: true, winnerTokenId: 42n },
    });
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await observeSettlement(config, clients, ledger);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("info");
    expect(relevant?.detail).toContain("42");
  });

  it("requested but unsettled for a long time -> reports a warning, not silent info", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients } = makeMockClients({
      "getRound:4": { closeTime: BigInt(nowSec - 60 * 60), settled: false, winnerTokenId: 0n },
    });
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await observeSettlement(config, clients, ledger);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("warn");
    expect(relevant?.detail).toMatch(/UNSETTLED/);
  });

  it("requested but unsettled only recently -> reports info, not a warning yet", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients } = makeMockClients({
      "getRound:4": { closeTime: BigInt(nowSec - 60), settled: false, winnerTokenId: 0n },
    });
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
    });

    const results = await observeSettlement(config, clients, ledger);
    const relevant = results.find((r) => r.detail.includes("round 4"));
    expect(relevant?.level).toBe("info");
  });

  it("REQUIREMENT: settled/skipped rounds are ignored - a round the ledger already removed as settled is never read or reported at all", async () => {
    const config = makeTestConfig();
    const { clients } = makeMockClients({
      // getRound:4 deliberately NOT mocked - if this round is ever read,
      // the test throws immediately.
    });
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 4n, requestId: 77n }],
      settledRounds: [4n], // removed from requestedRounds internally too - outstandingRequested() excludes it
    });

    const results = await observeSettlement(config, clients, ledger);
    expect(results.find((r) => r.detail.includes("round 4"))).toBeUndefined();
    expect(clients.robinhoodPublic.readContract).not.toHaveBeenCalled();
  });

  it("REQUIREMENT: an old requested-and-unsettled round (from long before the keeper was last online) is still reported, no fixed lookback", async () => {
    const config = makeTestConfig();
    const nowSec = Math.floor(Date.now() / 1000);
    const { clients } = makeMockClients({
      "getRound:1": { closeTime: BigInt(nowSec - 2 * 60 * 60), settled: false, winnerTokenId: 0n },
    });
    // Round 1 - as old as it gets, well outside any fixed 20-round window.
    const ledger = RoundLedger.withState(clients.robinhoodPublic, config.roundManager, {
      requestedRounds: [{ roundId: 1n, requestId: 5n }],
    });

    const results = await observeSettlement(config, clients, ledger);
    const relevant = results.find((r) => r.detail.includes("round 1"));
    expect(relevant).toBeDefined();
    expect(relevant?.level).toBe("warn");
  });
});
