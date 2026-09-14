# CLOG — Post-Deploy Frontend Handoff

Once the contracts are actually deployed and wired, this is the complete
list of what's needed to bring the frontend online — nothing more. The five
protocol addresses, chain id, and deployment block are entirely driven by
the tracked `deployments/robinhood-mainnet.json` manifest (see
`docs/DEPLOYMENTS.md` for why) — no code file hardcodes a contract address,
and as of this manifest architecture, `.env.production` is no longer the
place these seven values live either. Everything else (Reown project ID,
RPC/explorer URL, database, uploads) remains environment-driven as before.

## What you need to give me (or fill in directly in the manifest)

Robinhood Chain Mainnet, from `DeployRobinhoodChain.s.sol`'s logged output:

- Deployment block number — **must** come from `scripts/verify-deployment.sh`'s
  own binary-search output (or an equivalent real on-chain check), never
  guessed or assumed to be "the current block"
- `EligibilityRegistry` address
- `RoundManager` address
- `RewardVault` address
- `TickerNFT` address
- `TickerRegistry` address
- `ChainlinkRandomnessProvider` address *(not read by the frontend's own
  env.ts — recorded in the manifest's `$notReadByFrontend` block purely so
  `scripts/verify-deployment.sh` can cross-check it, not one of the five
  addresses `isProtocolConfigured` actually requires)*

Arbitrum One, from `DeployArbitrumWrapper.s.sol`'s logged output:

- `VRFWrapperOnArbitrum` address *(same as above — recorded for
  `scripts/verify-deployment.sh`'s own cross-chain code check, never read
  by the frontend itself; users never interact with Arbitrum directly, per
  the product's own design)*

Plus, still an environment variable (unchanged):

- The real Reown Project ID (from `https://cloud.reown.com`)

## Exact steps once you have all of that

1. **Verify on-chain first** — run `scripts/verify-deployment.sh` against
   real RPC access to both chains. It confirms code exists at every
   address, confirms the cross-contract getters actually match each other
   (catching an address swap that "code exists" alone would miss), and
   determines the real deployment block. Do not proceed until it reports
   zero failures.
2. **Update the manifest** — edit `deployments/robinhood-mainnet.json`:
   set `chainId`, `deploymentBlock` (from step 1's output), and the five
   `contracts.*` addresses. This file is tracked in git — commit it.
3. **Push** — `git push` the manifest update (and Reown project ID change,
   if any code change accompanied it — a pure manifest update still needs
   pushing, since unlike the old `.env.production`-only flow, this value
   now lives in git).
4. **Regenerate anything address-specific** — nothing to regenerate. ABIs
   are keyed by contract *shape*, not address (see
   `lib/web3/abis/README.md`) — they don't change when addresses change.
5. **VPS pull/build/restart** — for an ordinary manifest/address update
   with NO accompanying breaking DB migration, see `VPS_RUNBOOK.md`'s
   standard update sequence: `git pull origin main`, `npm ci` only if
   dependencies changed, `npm run build` (required — the manifest is
   baked in at build time, exactly like `NEXT_PUBLIC_*` values, see
   `.env.production.example`'s own header for why a restart alone is
   never enough), `systemctl restart clog`. **If the update also includes
   a migration that changes an existing table in a way the currently-
   running old code doesn't write compatibly with (this canary rollout's
   own migration 002 is exactly this case), use VPS_RUNBOOK.md's
   dedicated "Deployments with a breaking DB migration" section instead**
   — building before migrating, and migrating only while the app is
   stopped, so there is no window where the old app runs against the new
   schema.

## Sanity check after going live

For an ordinary update (no breaking migration):

```bash
cd /opt/clogged
git pull origin main
npm ci   # only if package.json/package-lock.json changed
sudo -u clog npm run build
sudo systemctl restart clog
curl -s https://clog.run/api/health
curl -s https://clog.run/api/ticker-metadata/1   # legacy HOOD (tokenId 1 = HOOD, already launched) - expect real metadata, NOT 404
```

Then load `https://clog.run` in a browser: the "Protocol contracts not
configured yet" messaging (in `TokenTable`, `TokenDetailPage`, `LaunchPage`,
etc.) should be gone, replaced by real onchain reads against the new
deployment.

For a deployment that includes a breaking DB migration (this canary
rollout's own migration 002), do NOT use the sequence above — see
`VPS_RUNBOOK.md`'s "Deployments with a breaking DB migration" section for
the exact build-first, stop/migrate/start sequence and its own rollback
procedure, and run all four of that section's smoke tests (health, legacy
HOOD metadata, canary metadata, canary artwork) — not just the two shown
above.

