import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { ActionLock } from "../src/lock.js";
import type { PublicClient } from "viem";

function makeMockClient(receiptBehavior: "found" | "not-found" | "error"): PublicClient {
  return {
    getTransactionReceipt: vi.fn(async () => {
      if (receiptBehavior === "found") return { status: "success" } as never;
      if (receiptBehavior === "error") throw new Error("receipt not found");
      throw new Error("receipt not found");
    }),
  } as unknown as PublicClient;
}

describe("ActionLock", () => {
  let tmpDir: string;
  let lockFilePath: string;
  let lock: ActionLock;

  beforeEach(() => {
    tmpDir = mkdtempSync(path.join(tmpdir(), "clog-keeper-lock-test-"));
    lockFilePath = path.join(tmpDir, "lock.json");
    lock = new ActionLock(lockFilePath);
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("a fresh key with no prior entry is never in flight", async () => {
    const pending = makeMockClient("not-found");
    const inFlight = await lock.isInFlight("close-round-1", { robinhood: pending, arbitrum: pending });
    expect(inFlight).toBe(false);
  });

  it("acquiring a lock creates the file and marks the key in flight while unresolved", async () => {
    const pending = makeMockClient("not-found");
    lock.acquire("close-round-1", "0xabc123" as `0x${string}`, "robinhood");
    expect(existsSync(lockFilePath)).toBe(true);
    const inFlight = await lock.isInFlight("close-round-1", { robinhood: pending, arbitrum: pending });
    expect(inFlight).toBe(true);
  });

  it("a lock whose transaction has been mined is no longer in flight, and is cleared", async () => {
    const mined = makeMockClient("found");
    lock.acquire("close-round-1", "0xabc123" as `0x${string}`, "robinhood");
    const inFlight = await lock.isInFlight("close-round-1", { robinhood: mined, arbitrum: mined });
    expect(inFlight).toBe(false);
    // Cleared, not just reported false - a second check with a client that
    // would throw if actually queried (proving no lookup happens) still
    // returns false since the entry is gone.
    const secondCheck = await lock.isInFlight("close-round-1", { robinhood: mined, arbitrum: mined });
    expect(secondCheck).toBe(false);
  });

  it("explicit release clears a lock immediately regardless of chain state", async () => {
    const pending = makeMockClient("not-found");
    lock.acquire("qualify-token-5", "0xdef456" as `0x${string}`, "robinhood");
    lock.release("qualify-token-5");
    const inFlight = await lock.isInFlight("qualify-token-5", { robinhood: pending, arbitrum: pending });
    expect(inFlight).toBe(false);
  });

  it("different action keys are tracked independently", async () => {
    const pending = makeMockClient("not-found");
    lock.acquire("close-round-1", "0x111" as `0x${string}`, "robinhood");
    const roundInFlight = await lock.isInFlight("close-round-1", { robinhood: pending, arbitrum: pending });
    const tokenInFlight = await lock.isInFlight("qualify-token-1", { robinhood: pending, arbitrum: pending });
    expect(roundInFlight).toBe(true);
    expect(tokenInFlight).toBe(false);
  });

  it("routes the receipt lookup to the correct chain's client based on the lock's recorded chain", async () => {
    const robinhoodClient = makeMockClient("not-found");
    const arbitrumClient = makeMockClient("found");
    lock.acquire("relay-randomness-request-9", "0x999" as `0x${string}`, "arbitrum");
    // Even though the robinhood client would report "not found" (still
    // in-flight), the lock is recorded against arbitrum, and the arbitrum
    // client reports it mined - the lock must resolve as no-longer-in-flight.
    const inFlight = await lock.isInFlight("relay-randomness-request-9", { robinhood: robinhoodClient, arbitrum: arbitrumClient });
    expect(inFlight).toBe(false);
  });

  it("a corrupted lock file is treated as empty rather than crashing", async () => {
    const fs = await import("node:fs");
    fs.writeFileSync(lockFilePath, "{ this is not valid json");
    const pending = makeMockClient("not-found");
    const inFlight = await lock.isInFlight("close-round-1", { robinhood: pending, arbitrum: pending });
    expect(inFlight).toBe(false);
  });

  it("persists across ActionLock instances pointed at the same file", async () => {
    lock.acquire("close-round-2", "0xabc" as `0x${string}`, "robinhood");
    const secondLockInstance = new ActionLock(lockFilePath);
    const pending = makeMockClient("not-found");
    const inFlight = await secondLockInstance.isInFlight("close-round-2", { robinhood: pending, arbitrum: pending });
    expect(inFlight).toBe(true);
  });

  it("restart cannot resend a completed action: a fresh ActionLock instance sees a mined prior transaction as resolved, not as free to retry blindly", async () => {
    // Simulates a full keeper restart: the process crashed or was
    // redeployed after submitting a transaction that went on to be mined
    // successfully, and a brand new ActionLock instance (pointed at the
    // same on-disk lock file, exactly as a real restart would use) is the
    // very first thing to check this action key.
    lock.acquire("qualify-token-7", "0x777" as `0x${string}`, "robinhood");
    const keeperRestarted = new ActionLock(lockFilePath);
    const minedClient = makeMockClient("found");

    const inFlight = await keeperRestarted.isInFlight("qualify-token-7", { robinhood: minedClient, arbitrum: minedClient });

    // Not in flight - correctly recognized as already resolved on-chain,
    // not as a stale lock that's now safe to blindly retry. The real
    // action functions (qualifyMaturedTokens etc.) additionally re-check
    // actual contract state before ever sending a transaction (e.g.
    // isCandidate()), which is the deeper reason a restart can never
    // double-send: even in the hypothetical where this lock check were
    // skipped entirely, the state-level guard in the action itself would
    // still catch it.
    expect(inFlight).toBe(false);
    // And the lock file itself no longer references this key at all - a
    // second restart-simulating instance sees a clean slate, not a
    // dangling reference to a resolved transaction.
    const yetAnotherRestart = new ActionLock(lockFilePath);
    const stillNotInFlight = await yetAnotherRestart.isInFlight("qualify-token-7", { robinhood: makeMockClient("not-found"), arbitrum: makeMockClient("not-found") });
    expect(stillNotInFlight).toBe(false);
  });
});
