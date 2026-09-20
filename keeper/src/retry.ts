import { logger } from "./logger.js";

/**
 * Retries a transient failure (RPC timeout, connection reset, a node
 * momentarily behind) with exponential backoff and jitter. Deliberately
 * does NOT retry on every error indiscriminately - a contract revert (e.g.
 * "round not over yet") is not a transient failure, it's the correct,
 * final answer for this poll cycle, and retrying it would just waste time
 * re-asking a question whose answer hasn't changed. isRetryable decides
 * which is which.
 */
export interface RetryOptions {
  maxAttempts: number;
  baseDelayMs: number;
  maxDelayMs: number;
  actionLabel: string;
}

const DEFAULT_OPTIONS: Omit<RetryOptions, "actionLabel"> = {
  maxAttempts: 3,
  baseDelayMs: 500,
  maxDelayMs: 8_000,
};

/** Transient/network-shaped errors worth retrying - connection resets,
 * timeouts, rate limits, and 5xx-shaped RPC failures. A contract revert
 * (require() message, "execution reverted", etc.) is NOT retried here -
 * it is the correct answer, not a failure to retry past. */
export function isRetryableError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  const lower = message.toLowerCase();
  const retryablePatterns = [
    "econnreset",
    "econnrefused",
    "etimedout",
    "timeout",
    "network",
    "fetch failed",
    "socket hang up",
    "429",
    "too many requests",
    "rate limit",
    "502",
    "503",
    "504",
    "gateway",
  ];
  return retryablePatterns.some((p) => lower.includes(p));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function withRetry<T>(fn: () => Promise<T>, options: RetryOptions): Promise<T> {
  const opts = { ...DEFAULT_OPTIONS, ...options };
  let lastError: unknown;

  for (let attempt = 1; attempt <= opts.maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const retryable = isRetryableError(err);
      if (!retryable || attempt === opts.maxAttempts) {
        throw err;
      }
      const backoff = Math.min(opts.baseDelayMs * 2 ** (attempt - 1), opts.maxDelayMs);
      const jitter = Math.random() * backoff * 0.2;
      const delay = backoff + jitter;
      logger.warn(opts.actionLabel, `attempt ${attempt}/${opts.maxAttempts} failed (retryable), backing off ${Math.round(delay)}ms`, {
        error: err instanceof Error ? err.message : String(err),
      });
      await sleep(delay);
    }
  }
  throw lastError;
}
