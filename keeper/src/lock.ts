import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import type { PublicClient } from "viem";

/**
 * Every state-changing action this keeper ever takes is ALSO already
 * idempotent at the contract level (see README.md's "security assumptions"
 * - e.g. closeRoundAndOpenNext() can never double-close the same round,
 * qualify() on an already-candidate token is a harmless no-op re-touch,
 * requestRandomnessForRound() explicitly requires !randomnessRequested,
 * relayRandomness() explicitly requires !relayed). This lock exists for a
 * DIFFERENT, narrower reason: without it, a short poll interval could see
 * the keeper send a second, fully redundant transaction for the same
 * action while the first one is still pending in the mempool (not yet
 * mined), wasting gas on a transaction that will simply revert once the
 * first one confirms, and creating unnecessary nonce contention. This is
 * an in-flight guard, not a correctness guard - correctness comes from the
 * contracts themselves.
 *
 * Deliberately a single flat JSON file, not a database: this keeper has
 * exactly one instance (systemd `Restart=on-failure` recovers a crashed
 * process, it never runs two copies at once - see the unit file), so
 * there is no concurrent-writer problem to solve here.
 */

interface LockEntry {
  txHash: `0x${string}`;
  chain: "robinhood" | "arbitrum";
  submittedAt: number; // unix ms
}

type LockState = Record<string, LockEntry>;

/** How long a lock entry is trusted before being treated as stale (e.g. the
 * transaction was dropped from the mempool and never mined, or the keeper
 * crashed mid-flight) and cleared automatically on next use. Generous on
 * purpose - both chains have fast blocks, but a stuck/underpriced tx could
 * plausibly sit for a while; this is a safety net, not a tight timer. */
const STALE_LOCK_MS = 15 * 60 * 1000; // 15 minutes

function readState(lockFilePath: string): LockState {
  if (!existsSync(lockFilePath)) return {};
  try {
    return JSON.parse(readFileSync(lockFilePath, "utf8")) as LockState;
  } catch {
    // A corrupted lock file must never crash the keeper or permanently
    // block every action - treat it as empty and let it be rewritten
    // cleanly on the next write.
    return {};
  }
}

function writeState(lockFilePath: string, state: LockState): void {
  mkdirSync(path.dirname(lockFilePath), { recursive: true });
  writeFileSync(lockFilePath, JSON.stringify(state, null, 2));
}

export class ActionLock {
  constructor(private lockFilePath: string) {}

  /** True if this action key has a lock entry that is neither stale nor
   * already resolved on-chain. Callers should skip sending a new
   * transaction for this key when this returns true. Also opportunistically
   * clears the entry if it turns out to be resolved or stale, so callers
   * never need to call `release` themselves for the normal case. */
  async isInFlight(key: string, publicClients: { robinhood: PublicClient; arbitrum: PublicClient }): Promise<boolean> {
    const state = readState(this.lockFilePath);
    const entry = state[key];
    if (!entry) return false;

    if (Date.now() - entry.submittedAt > STALE_LOCK_MS) {
      delete state[key];
      writeState(this.lockFilePath, state);
      return false;
    }

    const client = entry.chain === "robinhood" ? publicClients.robinhood : publicClients.arbitrum;
    try {
      const receipt = await client.getTransactionReceipt({ hash: entry.txHash });
      if (receipt) {
        // Resolved (mined, success or revert either way) - the on-chain
        // state is now authoritative, not this lock. Clear it.
        delete state[key];
        writeState(this.lockFilePath, state);
        return false;
      }
    } catch {
      // Not found yet (still pending, or never made it into a block) -
      // treat as still in-flight.
    }
    return true;
  }

  acquire(key: string, txHash: `0x${string}`, chain: "robinhood" | "arbitrum"): void {
    const state = readState(this.lockFilePath);
    state[key] = { txHash, chain, submittedAt: Date.now() };
    writeState(this.lockFilePath, state);
  }

  /** Explicit early release - used after a transaction is confirmed within
   * the same run, so a later action in the same loop iteration isn't
   * blocked by a lock that's already resolved. */
  release(key: string): void {
    const state = readState(this.lockFilePath);
    delete state[key];
    writeState(this.lockFilePath, state);
  }
}
