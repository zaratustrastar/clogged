# CLOG — Post-Deploy Frontend Handoff

Once the contracts are actually deployed and wired, this is the complete
list of what's needed to bring the frontend online — nothing more. The app
is entirely environment-driven (see `lib/web3/env.ts` and
`lib/web3/addresses.ts`) — no code file hardcodes a contract address, so no
source file needs editing for this, only `.env.production`.

## What you need to give me (or fill in directly on the VPS)

Robinhood Chain Mainnet, from `DeployRobinhoodChain.s.sol`'s logged output:

- Deployment block number
- `EligibilityRegistry` address
- `RoundManager` address
- `RewardVault` address
- `TickerNFT` address
- `TickerRegistry` address
- `ChainlinkRandomnessProvider` address *(not currently read by the
  frontend — recorded for completeness, not one of the five
  `NEXT_PUBLIC_*_ADDRESS` variables the app actually uses)*

Arbitrum One, from `DeployArbitrumWrapper.s.sol`'s logged output:

- `VRFWrapperOnArbitrum` address *(not read by the frontend at all — users
  never interact with Arbitrum directly, per the product's own design)*

Plus:

- The real Reown Project ID (from `https://cloud.reown.com`)

## Exact steps once you have all of that

1. **Insert/update env values** — edit `/opt/clogged/.env.production` (or
   hand me the values and I'll prepare the exact lines): set
   `NEXT_PUBLIC_DEPLOYMENT_BLOCK`, the five `NEXT_PUBLIC_*_ADDRESS`
   variables, and `NEXT_PUBLIC_REOWN_PROJECT_ID`.
2. **Regenerate anything address-specific** — nothing to regenerate. ABIs
   are keyed by contract *shape*, not address (see
   `lib/web3/abis/README.md`) — they don't change when addresses change.
   The only thing that changes is the env file.
3. **Build** — `cd /opt/clogged && npm run build` (required — `NEXT_PUBLIC_*`
   values are baked in at build time, see `.env.production.example`'s own
   header for why a restart alone is never enough).
4. **Push** — only relevant if the update also includes a code change (e.g.
   ABI regeneration for genuinely new contract functions); a pure env value
   update never requires a `git push` since `.env.production` is never
   committed.
5. **VPS pull/build/restart** — see `VPS_RUNBOOK.md`'s standard update
   sequence; for an env-only change, skip `git pull`/`npm ci` and go
   straight to `npm run build` + `sudo systemctl restart clog`.

## Sanity check after going live

```bash
curl -s https://clog.run/api/health
curl -s https://clog.run/api/ticker-metadata/1   # 404 until a real token 1 exists - expected
```

Then load `https://clog.run` in a browser: the "Protocol contracts not
configured yet" messaging (in `TokenTable`, `TokenDetailPage`, `LaunchPage`,
etc.) should be gone, replaced by real onchain reads.
