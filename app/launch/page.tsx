"use client";

import { useState, useEffect } from "react";
import { Cabinet } from "@/components/machine/Cabinet";
import { TickerSlot, OptionalMeta, type Availability } from "@/components/launch/TickerSlot";
import { LaunchDeck, type LaunchPhase } from "@/components/launch/LaunchDeck";
import { txMotionState } from "@/components/machine/motion";
import { useRef } from "react";
import { useLaunchToken, useTickerAvailability } from "@/lib/hooks/useProtocolActions";
import { tokenProfileStore } from "@/lib/metadata/TokenProfileStore";
import { useNow } from "@/lib/hooks/useNow";
import { formatCountdown } from "@/lib/format";

/* PROTOCOL BEHAVIOUR IS UNCHANGED.
 * useLaunchToken keeps owning: salt generation + storage, commit/reveal ordering,
 * fresh-from-chain reveal deadline, receipt waits, error surfacing. This page only
 * renders its phase. It adds no reads and no timers of its own beyond useNow, which
 * only formats a countdown from a value the hook already computed (revealAt) - it
 * never derives a NEW deadline.
 *
 * Runbook §0 mismatches found and fixed here (useLaunchToken's REAL return is
 * { execute, reveal, reset, phase, error, tokenId, revealAt, ticker } - confirmed
 * directly against lib/hooks/useProtocolActions.ts, not assumed):
 *   - launch.commit(...)         -> launch.execute(...) (no method named commit)
 *   - launch.error?.message      -> launch.error (already a plain string, not an
 *                                    Error object - `.message` on a string is undefined)
 *   - launch.status/launch.hash  -> do not exist; txMotionState's coarser
 *                                    idle/pending/success/error status is derived
 *                                    from `phase` instead (see toLaunchStatus below)
 *   - launch.explorerUrl         -> does not exist; the hook exposes no tx hash at
 *                                    all in its return, so there is nothing to build
 *                                    a link from - passed as null rather than
 *                                    invented (LaunchDeck's own prop type already
 *                                    allows null and hides the link)
 *   - launch.revealCountdown     -> does not exist; the hook exposes revealAt (a
 *                                    raw unix-ms timestamp) instead - formatted here
 *                                    via the existing formatCountdown, at the page
 *                                    level, exactly as the task asks (presentational
 *                                    components take strings, never compute a
 *                                    countdown themselves)
 *
 * The one presentational change: the phases are now three visible moments
 * (ENTER TICKER → SECURED / waiting → REVEAL) instead of one long form, and the
 * optional metadata is collapsed out of the critical path. */

/** Maps useLaunchToken's real 6-phase state machine onto txMotionState's coarser
 * idle/pending/success/error - "waiting" (the post-commit-receipt countdown to
 * reveal) reads as "success" because the commit transaction has already been
 * confirmed by the time the hook transitions to this phase (it only does so AFTER
 * its own `await publicClient.waitForTransactionReceipt(...)` resolves - confirmed
 * directly against the hook's source, not assumed). */
function toLaunchStatus(phase: LaunchPhase): "idle" | "pending" | "success" | "error" {
  if (phase === "committing" || phase === "revealing") return "pending";
  if (phase === "waiting" || phase === "live") return "success";
  if (phase === "error") return "error";
  return "idle";
}

export default function LaunchPage() {
  const [ticker, setTicker] = useState("");
  const [name, setName] = useState("");
  const [optionalOpen, setOptionalOpen] = useState(false);
  const now = useNow(1000);
  // OptionalMeta's own x/telegram/website <input>s are uncontrolled (no
  // value/onChange - confirmed directly against the handoff's own
  // TickerSlot.tsx) but do carry real name="..." attributes, so their
  // values are read via FormData at reveal time instead - this preserves
  // the existing "stored off-chain after the token is live" behavior
  // without adding controlled state to a presentational component the
  // task asks not to rewrite. The image field IS controlled state (below)
  // rather than FormData-read, since a file upload needs to happen (and
  // be able to fail, and be retried) well before reveal, not merely be
  // read off at that moment the way a plain text field can be.
  const formRef = useRef<HTMLFormElement>(null);

  const [imageFile, setImageFile] = useState<File | null>(null);
  const [imagePreviewUrl, setImagePreviewUrl] = useState<string | null>(null);
  const [imageRemoteUrl, setImageRemoteUrl] = useState<string | null>(null);
  const [imageStatus, setImageStatus] = useState<"idle" | "uploading" | "error">("idle");
  const [imageError, setImageError] = useState<string | null>(null);
  // A ref, not just the state above, specifically so the unmount-only
  // cleanup effect below can read the CURRENT url without needing to
  // depend on (and therefore re-run on every change of) imagePreviewUrl -
  // an effect with [] deps only ever closes over the state's value from
  // the initial render otherwise, which would always be null.
  const imagePreviewUrlRef = useRef<string | null>(null);

  useEffect(() => {
    imagePreviewUrlRef.current = imagePreviewUrl;
  }, [imagePreviewUrl]);

  // Object URLs created via URL.createObjectURL are never freed by the
  // browser automatically - revoke whichever one is current when the page
  // itself unmounts (the individual replace/clear paths below already
  // revoke their own prior URL as they go).
  useEffect(() => {
    return () => {
      if (imagePreviewUrlRef.current) URL.revokeObjectURL(imagePreviewUrlRef.current);
    };
  }, []);

  async function handleImageFile(file: File) {
    // Client-side pre-check mirrors the real, authoritative server-side
    // validation (lib/storage/filesystem.ts's own ALLOWED_MIME_TYPES/
    // MAX_FILE_SIZE_BYTES) - this is only for immediate feedback before a
    // network round trip; the server's own check is what actually decides
    // whether the file is accepted, never bypassed by this one.
    const allowed = ["image/png", "image/jpeg", "image/webp", "image/gif"];
    if (!allowed.includes(file.type)) {
      setImageStatus("error");
      setImageError("Unsupported file type - use PNG, JPG, WEBP, or GIF.");
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      setImageStatus("error");
      setImageError("Image too large - max 5 MB.");
      return;
    }

    if (imagePreviewUrl) URL.revokeObjectURL(imagePreviewUrl);
    setImageFile(file);
    setImagePreviewUrl(URL.createObjectURL(file));
    setImageRemoteUrl(null);
    setImageStatus("uploading");
    setImageError(null);

    try {
      const body = new FormData();
      body.set("image", file);
      const res = await fetch("/api/upload-image", { method: "POST", body });
      const data = await res.json();
      if (!res.ok) {
        setImageStatus("error");
        setImageError(typeof data?.error === "string" ? data.error : "Upload failed - try again.");
        return;
      }
      setImageRemoteUrl(data.url as string);
      setImageStatus("idle");
    } catch {
      setImageStatus("error");
      setImageError("Upload failed - check your connection and try again.");
    }
  }

  function handleImageClear() {
    if (imagePreviewUrl) URL.revokeObjectURL(imagePreviewUrl);
    setImageFile(null);
    setImagePreviewUrl(null);
    setImageRemoteUrl(null);
    setImageStatus("idle");
    setImageError(null);
  }

  const availability = useTickerAvailability(ticker);
  const launch = useLaunchToken();

  const phase: LaunchPhase = (launch.phase ?? "idle") as LaunchPhase;

  // Runbook §0: useTickerAvailability's real return is NOT an AsyncState
  // (no .isLoading/.data at all) - it's a discriminated union
  // ({status: "idle"|"checking"|"available"|"taken"|"reserved"} |
  // {status: "invalid", reason}) that already does its own debouncing and
  // length/charset validation internally (confirmed directly against
  // useProtocolActions.ts). Mapped 1:1 onto TickerSlot's own Availability
  // union (status -> kind; "reserved" - CLOG's own reserved ticker - reads
  // as "taken", since Availability has no separate reserved state).
  const avail: Availability =
    availability.status === "idle" ? { kind: "idle" }
    : availability.status === "checking" ? { kind: "checking" }
    : availability.status === "available" ? { kind: "available" }
    : availability.status === "invalid" ? { kind: "invalid", reason: availability.reason }
    : { kind: "taken" }; // "taken" or "reserved"

  const canSubmit = avail.kind === "available" && name.trim().length > 0;
  const revealCountdown = launch.revealAt ? formatCountdown(new Date(launch.revealAt).toISOString(), now) : null;

  return (
    <form
      ref={formRef}
      onSubmit={(e) => e.preventDefault()}
      className="mx-auto flex max-w-[1240px] flex-col gap-[22px] px-5 pb-24 pt-7"
    >
      <header className="flex flex-col gap-2">
        <span className="font-mono text-label text-amber">LAUNCH · TWO TRANSACTIONS</span>
        <h1 className="m-0 font-display text-[clamp(28px,4vw,42px)] leading-[1.02] tracking-[-0.025em]">
          Load a ticker into the machine
        </h1>
        <p className="m-0 max-w-[62ch] text-[15px] leading-[1.6] text-ink-400 text-pretty">
          Secure the ticker first, wait out the reveal delay, then mint. The button stays
          down while your wallet holds the transaction, and nothing says confirmed until the
          receipt lands.
        </p>
      </header>

      <div className="grid grid-cols-1 items-start gap-[18px] lg:grid-cols-[minmax(0,1fr)_minmax(280px,360px)]">
        <Cabinet
          state={txMotionState({ status: toLaunchStatus(phase), disabled: !canSubmit && phase === "idle" })}
          className="min-w-0"
        >
          <div className="flex flex-col gap-2.5 rounded-md border border-edge-hard bg-gradient-to-b from-chassis-700 to-chassis-900 p-4">
            <p className="m-0 font-mono text-label text-ink-500">
              STEP {phase === "waiting" || phase === "revealing" || phase === "live" ? 2 : 1} OF 2
            </p>
            <div className="flex gap-1.5">
              <span className="h-1 flex-1 bg-amber" />
              <span className={`h-1 flex-1 ${phase === "waiting" || phase === "revealing" || phase === "live" ? "bg-amber" : "bg-edge-hair"}`} />
            </div>
          </div>

          <div className="mt-3 flex flex-col gap-3.5">
            <TickerSlot
              ticker={ticker}
              onTicker={setTicker}
              name={name}
              onName={setName}
              availability={avail}
            />
            <OptionalMeta
              open={optionalOpen}
              onToggle={() => setOptionalOpen((v) => !v)}
              imagePreviewUrl={imagePreviewUrl}
              imageStatus={imageStatus}
              imageError={imageError}
              onImageFile={handleImageFile}
              onImageClear={handleImageClear}
            />
          </div>

          <LaunchDeck
            phase={phase}
            errorMessage={launch.error ?? null}
            txHash={null}
            explorerUrl={null}
            revealUnlocksIn={revealCountdown}
            disabled={!canSubmit && phase === "idle"}
            onPrimary={() => {
              if (phase === "idle" || phase === "error") {
                launch.execute({ ticker });
              } else if (phase === "waiting") {
                launch.reveal().then((result) => {
                  if (!result) return; // reveal itself already surfaced the error via launch.error
                  const fd = formRef.current ? new FormData(formRef.current) : null;
                  tokenProfileStore.set({
                    tokenId: result.tokenId,
                    displayName: name || undefined,
                    imageUrl: imageRemoteUrl ?? undefined,
                    xUrl: (fd?.get("x") as string) || undefined,
                    telegramUrl: (fd?.get("telegram") as string) || undefined,
                    websiteUrl: (fd?.get("website") as string) || undefined,
                  });
                });
              }
            }}
            tokenHref={phase === "live" ? `/token/${ticker}` : undefined}
          />
        </Cabinet>

        <aside className="flex min-w-0 flex-col gap-3">
          <div className="flex flex-col gap-3 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-5">
            <span className="font-mono text-label text-amber">WHY TWO STEPS</span>
            <p className="m-0 text-sm leading-[1.6] text-ink-400 text-pretty">
              Committing the ticker hashed with a salt means nobody can watch the mempool and
              front-run your label. The reveal delay belongs to the protocol, not the interface —
              we show it counting down instead of spinning.
            </p>
            <dl className="m-0 flex flex-col gap-2 font-mono text-[11.5px] text-ink-400">
              <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
                <dt>COMMIT</dt><dd className="m-0 text-ink-100">hash(ticker + salt)</dd>
              </div>
              <div className="flex justify-between gap-2.5 border-b border-dashed border-edge-hair pb-2">
                <dt>SALT STORED</dt><dd className="m-0 text-ink-100">this browser only</dd>
              </div>
              <div className="flex justify-between gap-2.5">
                <dt>REVEAL</dt><dd className="m-0 text-ink-100">mints ERC-20 + TickerNFT</dd>
              </div>
            </dl>
            <p className="m-0 text-xs leading-[1.5] text-bad">
              Do not clear site data between the two steps — the salt lives here.
            </p>
          </div>

          <div className="flex flex-col gap-3 border border-edge-soft bg-gradient-to-b from-chassis-600 to-chassis-800 p-5">
            <span className="font-mono text-label text-ok">WHAT YOU GET</span>
            <div className="flex flex-wrap gap-2.5">
              <div className="min-w-0 flex-1 border border-edge-hair bg-chassis-900 p-3">
                <p className="m-0 font-mono text-label text-ink-500">TICKER NFT</p>
                <p className="mt-1.5 text-[12.5px] text-ink-100">The label, the slot, creator economics</p>
              </div>
              <div className="min-w-0 flex-1 border border-edge-hair bg-chassis-900 p-3">
                <p className="m-0 font-mono text-label text-ink-500">ERC-20</p>
                <p className="mt-1.5 text-[12.5px] text-ink-100">Tradeable on the curve immediately</p>
              </div>
            </div>
            <p className="m-0 text-[12.5px] leading-[1.55] text-ink-500">
              Your token is not a prize yet. It qualifies once the curve reserve holds the
              threshold long enough.
            </p>
          </div>
        </aside>
      </div>
    </form>
  );
}
