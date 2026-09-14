import { describe, it, expect, vi } from "vitest";
import { closeDueRounds } from "../../src/actions/closeRounds.js";
import { makeTestConfig, makeMockClients, makeNoOpLock } from "../testHelpers.js";

describe("closeDueRounds decision path", () => {
  it("round due (now >= openTime + roundDuration) -> closes it", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      currentRoundOpenTime: nowSec - 4000n, // opened well before roundDuration ago
      roundDuration: 3600n, // 1 hour - so it's overdue
    });
    const lock = makeNoOpLock();

    const result = await closeDueRounds(config, clients, lock as never);

    expect(result.acted).toBe(true);
    expect(writeContract).toHaveBeenCalledTimes(1);
    expect(writeContract.mock.calls[0][0]).toMatchObject({ functionName: "closeRoundAndOpenNext" });
  });

  it("round NOT due yet -> does nothing, sends no transaction", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      currentRoundOpenTime: nowSec - 100n, // opened only 100s ago
      roundDuration: 3600n, // needs a full hour
    });
    const lock = makeNoOpLock();

    const result = await closeDueRounds(config, clients, lock as never);

    expect(result.acted).toBe(false);
    expect(result.detail).toMatch(/not due yet/);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("round exactly at the boundary (now == openTime + roundDuration) -> closes it (contract's own >= check)", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      currentRoundOpenTime: nowSec - 3600n,
      roundDuration: 3600n,
    });
    const lock = makeNoOpLock();

    const result = await closeDueRounds(config, clients, lock as never);
    expect(result.acted).toBe(true);
    expect(writeContract).toHaveBeenCalledTimes(1);
  });

  it("already-advanced round (freshly opened, not yet due under its own new timing) -> does nothing", async () => {
    // Simulates checking again immediately after a prior close already
    // advanced currentRoundId/currentRoundOpenTime - the new round has its
    // own fresh openTime and is not due under its own roundDuration.
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 6n, // advanced from 5 to 6
      currentRoundOpenTime: nowSec, // just opened
      roundDuration: 3600n,
    });
    const lock = makeNoOpLock();

    const result = await closeDueRounds(config, clients, lock as never);
    expect(result.acted).toBe(false);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("a close already in flight (lock) -> skips sending a second, redundant transaction", async () => {
    const config = makeTestConfig();
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      currentRoundOpenTime: nowSec - 4000n,
      roundDuration: 3600n,
    });
    const lock = { isInFlight: vi.fn(async () => true), acquire: vi.fn(), release: vi.fn() };

    const result = await closeDueRounds(config, clients, lock as never);
    expect(result.acted).toBe(false);
    expect(result.detail).toMatch(/already in flight/);
    expect(writeContract).not.toHaveBeenCalled();
  });

  it("--dry-run: reports what it would do but sends no transaction and acquires no lock", async () => {
    const config = makeTestConfig({ dryRun: true });
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const { clients, writeContract } = makeMockClients({
      currentRoundId: 5n,
      currentRoundOpenTime: nowSec - 4000n,
      roundDuration: 3600n,
    });
    const lock = makeNoOpLock();

    const result = await closeDueRounds(config, clients, lock as never);
    expect(result.acted).toBe(true);
    expect(result.detail).toMatch(/\[dry-run\]/);
    expect(writeContract).not.toHaveBeenCalled();
    expect(lock.acquire).not.toHaveBeenCalled();
  });
});
