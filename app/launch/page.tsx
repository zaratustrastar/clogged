"use client";

import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAccount } from "wagmi";
import { Button } from "@/components/ui/Button";
import { Panel } from "@/components/ui/Panel";
import { useTickerAvailability, useLaunchToken } from "@/lib/hooks/useProtocolActions";
import { tokenProfileStore, isMetadataPersistenceConfigured } from "@/lib/metadata/TokenProfileStore";
import {
  LAUNCH_PRICE_ETH,
  TOTAL_SUPPLY,
  CURVE_ALLOCATION,
  CLOG_ALLOCATION,
  MAX_TICKER_LENGTH,
} from "@/lib/constants";
import { formatCompact } from "@/lib/format";
import { isProtocolConfigured } from "@/lib/web3/env";

function AvailabilityMessage({ ticker }: { ticker: string }) {
  const availability = useTickerAvailability(ticker);

  if (availability.status === "idle") return null;
  if (availability.status === "checking")
    return <p className="mt-2 text-xs text-ink-dim">Checking availability…</p>;
  if (availability.status === "available")
    return <p className="mt-2 text-xs text-cyan">Available</p>;
  if (availability.status === "taken")
    return <p className="mt-2 text-xs text-danger">Already launched</p>;
  if (availability.status === "reserved")
    return (
      <p className="mt-2 text-xs text-danger">
        Reserved ticker — CLOG cannot be launched here. Official $CLOG launches on Pons.
      </p>
    );
  if (availability.status === "invalid")
    return <p className="mt-2 text-xs text-danger">{availability.reason}</p>;
  return null;
}

function useRevealCountdown(revealAt: number | null) {
  const [remaining, setRemaining] = useState(0);
  useEffect(() => {
    if (!revealAt) {
      setRemaining(0);
      return;
    }
    setRemaining(Math.max(0, Math.ceil((revealAt - Date.now()) / 1000)));
    const id = setInterval(() => {
      setRemaining(Math.max(0, Math.ceil((revealAt - Date.now()) / 1000)));
    }, 250);
    return () => clearInterval(id);
  }, [revealAt]);
  return remaining;
}

export default function LaunchPage() {
  const router = useRouter();
  const { isConnected } = useAccount();
  const [ticker, setTicker] = useState("");
  const [name, setName] = useState("");
  const [imagePreview, setImagePreview] = useState<string | null>(null);
  const [xUrl, setXUrl] = useState("");
  const [telegramUrl, setTelegramUrl] = useState("");
  const [websiteUrl, setWebsiteUrl] = useState("");
  const availability = useTickerAvailability(ticker);
  const { execute, reveal, phase, error, tokenId, revealAt } = useLaunchToken();
  const remaining = useRevealCountdown(revealAt);

  const canLaunch =
    isConnected && isProtocolConfigured && availability.status === "available" && phase === "idle";

  function onImageChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setImagePreview(URL.createObjectURL(file));
  }

  async function onSecureTicker() {
    await execute({ ticker });
  }

  async function onCreateToken() {
    await reveal();
    if (tokenId !== null) {
      await tokenProfileStore.set({
        tokenId,
        displayName: name || undefined,
        imageUrl: imagePreview ?? undefined,
        xUrl: xUrl || undefined,
        telegramUrl: telegramUrl || undefined,
        websiteUrl: websiteUrl || undefined,
      });
    }
  }

  if (phase === "live" && tokenId !== null) {
    return (
      <div className="content-container flex flex-col items-center py-24 text-center">
        <span className="mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-cyan/15 text-cyan">
          ✓
        </span>
        <h1 className="font-display text-2xl font-semibold text-ink">{ticker.toUpperCase()} is live</h1>
        <p className="mt-2 max-w-sm text-sm text-ink-dim">
          Your token has launched with a fixed 1B supply. You now hold the TickerNFT for{" "}
          {ticker.toUpperCase()}.
        </p>
        {!isMetadataPersistenceConfigured && (imagePreview || xUrl || telegramUrl || websiteUrl) && (
          <p className="mt-2 max-w-sm text-xs text-gold">
            Note: image and social links aren&apos;t saved anywhere yet — metadata persistence isn&apos;t
            configured for this deployment.
          </p>
        )}
        <div className="mt-6 flex gap-3">
          <Button onClick={() => router.push(`/token/${ticker.toLowerCase()}`)}>View token</Button>
          <Button variant="secondary" onClick={() => router.push("/dashboard")}>
            Go to dashboard
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="content-container max-w-xl py-12">
      <h1 className="font-display text-2xl font-semibold text-ink">Launch a token</h1>
      <p className="mt-1 text-sm text-ink-dim">One action, one fee. No liquidity to provide.</p>

      {!isProtocolConfigured && (
        <p className="mt-4 rounded border border-gold/40 bg-gold/5 px-3 py-2 text-xs text-gold">
          Protocol contracts not configured yet.
        </p>
      )}

      <Panel className="mt-8 p-6">
        <label className="block text-xs font-medium text-ink-dim">Token name (display only)</label>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Cat Coin"
          maxLength={40}
          disabled={phase !== "idle"}
          className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2.5 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
        />

        <label className="mt-5 block text-xs font-medium text-ink-dim">Ticker</label>
        <div className="relative mt-1.5">
          <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-faint">$</span>
          <input
            value={ticker}
            onChange={(e) => setTicker(e.target.value.toUpperCase().slice(0, MAX_TICKER_LENGTH))}
            placeholder="CAT"
            disabled={phase !== "idle"}
            className="w-full rounded border border-border bg-surface-raised py-2.5 pl-7 pr-3 text-sm font-mono uppercase text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
          />
        </div>
        {phase === "idle" && <AvailabilityMessage ticker={ticker} />}

        <label className="mt-5 block text-xs font-medium text-ink-dim">Image</label>
        <div className="mt-1.5 flex items-center gap-3">
          {imagePreview ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={imagePreview} alt="Token preview" className="h-12 w-12 rounded object-cover" />
          ) : (
            <div className="flex h-12 w-12 items-center justify-center rounded border border-dashed border-border text-ink-faint">?</div>
          )}
          <label className="cursor-pointer rounded border border-border-strong px-3 py-2 text-xs font-medium text-ink-dim hover:text-ink">
            Upload image
            <input type="file" accept="image/*" className="hidden" onChange={onImageChange} disabled={phase !== "idle"} />
          </label>
        </div>

        <div className="mt-5 grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div>
            <label className="block text-xs font-medium text-ink-dim">X (optional)</label>
            <input
              value={xUrl}
              onChange={(e) => setXUrl(e.target.value)}
              placeholder="x.com/…"
              disabled={phase !== "idle"}
              className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
            />
          </div>
          <div>
            <label className="block text-xs font-medium text-ink-dim">Telegram (optional)</label>
            <input
              value={telegramUrl}
              onChange={(e) => setTelegramUrl(e.target.value)}
              placeholder="t.me/…"
              disabled={phase !== "idle"}
              className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
            />
          </div>
          <div>
            <label className="block text-xs font-medium text-ink-dim">Website (optional)</label>
            <input
              value={websiteUrl}
              onChange={(e) => setWebsiteUrl(e.target.value)}
              placeholder="https://…"
              disabled={phase !== "idle"}
              className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60 disabled:opacity-50"
            />
          </div>
        </div>
        {!isMetadataPersistenceConfigured && (
          <p className="mt-2 text-xs text-ink-faint">
            Image and social links aren&apos;t persisted anywhere yet — see the metadata note in the
            project report. They won&apos;t be saved after this page closes.
          </p>
        )}

        <div className="mt-6 rounded border border-border bg-surface-raised p-4 text-xs text-ink-dim">
          <div className="flex justify-between">
            <span>Total supply</span>
            <span className="font-mono text-ink">{formatCompact(TOTAL_SUPPLY)}</span>
          </div>
          <div className="mt-1.5 flex justify-between">
            <span>Bonding curve</span>
            <span className="font-mono text-ink">{formatCompact(CURVE_ALLOCATION)}</span>
          </div>
          <div className="mt-1.5 flex justify-between">
            <span>CLOG reserve</span>
            <span className="font-mono text-ink">{formatCompact(CLOG_ALLOCATION)}</span>
          </div>
          <div className="mt-1.5 flex justify-between">
            <span>Launch fee</span>
            <span className="font-mono text-ink">{LAUNCH_PRICE_ETH} ETH</span>
          </div>
          <div className="mt-1.5 flex justify-between">
            <span>Creator liquidity</span>
            <span className="text-ink">0 ETH</span>
          </div>
          <div className="mt-1.5 flex justify-between">
            <span>Network gas</span>
            <span className="text-ink">Wallet estimate</span>
          </div>
        </div>

        {error && <p className="mt-4 text-xs text-danger">{error}</p>}

        {phase === "idle" && (
          <Button fullWidth size="lg" className="mt-6" disabled={!canLaunch} onClick={onSecureTicker}>
            {!isConnected ? "Connect wallet to launch" : "Secure ticker"}
          </Button>
        )}
        {phase === "committing" && (
          <Button fullWidth size="lg" className="mt-6" disabled>
            Confirm in wallet…
          </Button>
        )}
        {phase === "waiting" && (
          <Button fullWidth size="lg" className="mt-6" disabled={remaining > 0} onClick={onCreateToken}>
            {remaining > 0 ? `Create token in ${remaining}s` : `Create token · ${LAUNCH_PRICE_ETH} ETH`}
          </Button>
        )}
        {phase === "revealing" && (
          <Button fullWidth size="lg" className="mt-6" disabled>
            Confirm in wallet…
          </Button>
        )}
        {phase === "waiting" && (
          <p className="mt-2 text-center text-xs text-ink-faint">
            Ticker reserved — a short protocol delay protects against front-running before you create
            the token.
          </p>
        )}
      </Panel>
    </div>
  );
}
