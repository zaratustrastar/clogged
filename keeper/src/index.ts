import { loadConfig } from "./config.js";
import { createClients } from "./clients.js";
import { ActionLock } from "./lock.js";
import { TokenWatchlist } from "./tokenWatchlist.js";
import { logger } from "./logger.js";
import { withRetry } from "./retry.js";
import { closeDueRounds } from "./actions/closeRounds.js";
import { qualifyMaturedTokens } from "./actions/qualifyTokens.js";
import { retryFailedRandomness } from "./actions/retryRandomness.js";
import { relayFulfilledRandomness } from "./actions/relayRandomness.js";
import { observeSettlement } from "./actions/observeSettlement.js";
import { checkFundingHealth } from "./actions/fundingHealth.js";

/**
 * The keeper's own decision loop, run once per poll interval. Order is
 * deliberate: close due rounds first (this can also trigger the first
 * randomness request attempt for the round just closed), then qualify any
 * matured tokens for the round now open (so they're candidates before the
 * NEXT close), then retry any randomness requests that failed earlier,
 * then relay any results Arbitrum has already fulfilled, then the two
 * purely observational checks last. Every step is wrapped in withRetry
 * (transient RPC failures only - see retry.ts) AND a try/catch, so one
 * step's exhausted retries or genuine failure never blocks the others.
 */
async function runOnce(
  config: ReturnType<typeof loadConfig>,
  clients: ReturnType<typeof createClients>,
  lock: ActionLock,
  watchlist: TokenWatchlist
): Promise<void> {
  const steps: { name: string; run: () => Promise<{ acted: boolean; detail: string } | { acted: boolean; detail: string }[]> }[] = [
    { name: "closeDueRounds", run: () => closeDueRounds(config, clients, lock) },
    { name: "qualifyMaturedTokens", run: () => qualifyMaturedTokens(config, clients, lock, watchlist) },
    { name: "retryFailedRandomness", run: () => retryFailedRandomness(config, clients, lock) },
    { name: "relayFulfilledRandomness", run: () => relayFulfilledRandomness(config, clients, lock) },
  ];

  for (const step of steps) {
    try {
      const result = await withRetry(step.run, { maxAttempts: 3, baseDelayMs: 500, maxDelayMs: 8_000, actionLabel: step.name });
      const items = Array.isArray(result) ? result : [result];
      for (const item of items) {
        logger.info(step.name, item.detail, { acted: item.acted });
      }
    } catch (err) {
      logger.error(step.name, `failed after retries: ${(err as Error).message}`);
    }
  }

  try {
    const settlement = await withRetry(() => observeSettlement(config, clients), {
      maxAttempts: 3,
      baseDelayMs: 500,
      maxDelayMs: 8_000,
      actionLabel: "observeSettlement",
    });
    for (const item of settlement) logger[item.level]("observeSettlement", item.detail);
  } catch (err) {
    logger.error("observeSettlement", `failed after retries: ${(err as Error).message}`);
  }

  try {
    const funding = await withRetry(() => checkFundingHealth(config, clients), {
      maxAttempts: 3,
      baseDelayMs: 500,
      maxDelayMs: 8_000,
      actionLabel: "fundingHealth",
    });
    for (const item of funding) logger[item.level]("fundingHealth", item.detail);
  } catch (err) {
    logger.error("fundingHealth", `failed after retries: ${(err as Error).message}`);
  }
}

async function main(): Promise<void> {
  const config = loadConfig();
  const clients = createClients(config);
  const lock = new ActionLock(config.lockFilePath);

  logger.info("startup", "CLOG keeper starting", {
    dryRun: config.dryRun,
    keeperAddress: clients.keeperAddress,
    pollIntervalMs: config.pollIntervalMs,
    deploymentBlock: config.deploymentBlock.toString(),
  });
  if (config.dryRun) {
    logger.info("startup", "DRY-RUN MODE: no transaction will ever be sent, no lock file entry written for a dry-run action.");
  }

  const watchlist = await TokenWatchlist.build(clients.robinhoodPublic, config.eligibilityRegistry, config.deploymentBlock);
  logger.info(
    "startup",
    `token watchlist reconstructed from onchain event history: ${watchlist.size} known token(s), ${watchlist.activeStreakCount} with an active above-threshold streak right now`,
    {
    fromBlock: config.deploymentBlock.toString(),
  });

  // Single-shot mode for dry-run/manual invocation and for testing -
  // KEEPER_RUN_ONCE=true (or --dry-run alone, which implies one pass is
  // usually what an operator wants to inspect) exits after one iteration
  // instead of looping forever.
  const runOnceOnly = config.dryRun || process.env.KEEPER_RUN_ONCE === "true";

  if (runOnceOnly) {
    await runOnce(config, clients, lock, watchlist);
    logger.info("shutdown", "Single pass complete, exiting.");
    return;
  }

  // Graceful shutdown: SIGTERM (systemd's own default stop signal - see
  // systemd/clog-keeper.service) and SIGINT (Ctrl+C) both let any
  // in-flight loop iteration finish before exiting, rather than being
  // killed mid-transaction-submission. A second signal forces immediate
  // exit, in case a hung RPC call is preventing graceful completion.
  let shuttingDown = false;
  let forceExit = false;
  const requestShutdown = (signal: string) => {
    if (shuttingDown) {
      logger.warn("shutdown", `received ${signal} again - forcing immediate exit`);
      forceExit = true;
      return;
    }
    shuttingDown = true;
    logger.info("shutdown", `received ${signal}, finishing current loop iteration then exiting gracefully`);
  };
  process.on("SIGTERM", () => requestShutdown("SIGTERM"));
  process.on("SIGINT", () => requestShutdown("SIGINT"));

  while (!shuttingDown && !forceExit) {
    await runOnce(config, clients, lock, watchlist);
    if (shuttingDown || forceExit) break;
    await new Promise((resolve) => setTimeout(resolve, config.pollIntervalMs));
  }
  logger.info("shutdown", "Graceful shutdown complete.");
}

main()
  .then(() => {
    process.exitCode = 0;
  })
  .catch((err) => {
    logger.error("startup", `Fatal: ${(err as Error).message}`);
    process.exitCode = 1;
  });
