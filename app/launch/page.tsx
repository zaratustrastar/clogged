"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/Button";
import { Panel } from "@/components/ui/Panel";
import { useTickerAvailability, useLaunchToken } from "@/lib/hooks/useProtocolActions";
import {
  LAUNCH_PRICE_ETH,
  TOTAL_SUPPLY,
  CURVE_ALLOCATION,
  CLOG_ALLOCATION,
  MAX_TICKER_LENGTH,
} from "@/lib/constants";
import { formatCompact } from "@/lib/format";

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

export default function LaunchPage() {
  const router = useRouter();
  const [ticker, setTicker] = useState("");
  const [name, setName] = useState("");
  const [imagePreview, setImagePreview] = useState<string | null>(null);
  const availability = useTickerAvailability(ticker);
  const { execute, status, error } = useLaunchToken();

  const canLaunch = availability.status === "available" && name.trim().length > 0 && status !== "pending";

  function onImageChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    setImagePreview(URL.createObjectURL(file));
  }

  async function onLaunch() {
    await execute({ ticker, name });
  }

  if (status === "success") {
    return (
      <div className="content-container flex flex-col items-center py-24 text-center">
        <span className="mb-4 flex h-12 w-12 items-center justify-center rounded-full bg-cyan/15 text-cyan">
          ✓
        </span>
        <h1 className="font-display text-2xl font-semibold text-ink">
          {ticker.toUpperCase()} is live
        </h1>
        <p className="mt-2 max-w-sm text-sm text-ink-dim">
          Your token has launched with a fixed 1B supply. You now hold the TickerNFT for{" "}
          {ticker.toUpperCase()}.
        </p>
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

      <Panel className="mt-8 p-6">
        <label className="block text-xs font-medium text-ink-dim">Token name</label>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="e.g. Cat Coin"
          maxLength={40}
          className="mt-1.5 w-full rounded border border-border bg-surface-raised px-3 py-2.5 text-sm text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60"
        />

        <label className="mt-5 block text-xs font-medium text-ink-dim">Ticker</label>
        <div className="relative mt-1.5">
          <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-faint">
            $
          </span>
          <input
            value={ticker}
            onChange={(e) => setTicker(e.target.value.toUpperCase().slice(0, MAX_TICKER_LENGTH))}
            placeholder="CAT"
            className="w-full rounded border border-border bg-surface-raised py-2.5 pl-7 pr-3 text-sm font-mono uppercase text-ink placeholder:text-ink-faint outline-none focus:border-cyan/60"
          />
        </div>
        <AvailabilityMessage ticker={ticker} />

        <label className="mt-5 block text-xs font-medium text-ink-dim">Image (optional)</label>
        <div className="mt-1.5 flex items-center gap-3">
          {imagePreview ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={imagePreview} alt="Token preview" className="h-12 w-12 rounded object-cover" />
          ) : (
            <div className="flex h-12 w-12 items-center justify-center rounded border border-dashed border-border text-ink-faint">
              ?
            </div>
          )}
          <label className="cursor-pointer rounded border border-border-strong px-3 py-2 text-xs font-medium text-ink-dim hover:text-ink">
            Upload image
            <input type="file" accept="image/*" className="hidden" onChange={onImageChange} />
          </label>
        </div>

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
            <span>Liquidity required</span>
            <span className="text-ink">None</span>
          </div>
        </div>

        {error && <p className="mt-4 text-xs text-danger">{error}</p>}

        <Button fullWidth size="lg" className="mt-6" disabled={!canLaunch} onClick={onLaunch}>
          {status === "pending" ? "Launching…" : `Launch token · ${LAUNCH_PRICE_ETH} ETH`}
        </Button>
      </Panel>
    </div>
  );
}
