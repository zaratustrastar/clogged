"use client";

import { useState } from "react";
import { prizeSkin } from "@/components/machine/Claw";
import { shouldResetImageFailure } from "@/components/machine/tokenAvatarLogic";

export { shouldResetImageFailure } from "@/components/machine/tokenAvatarLogic";

/**
 * Renders a token's real uploaded image (from its persisted off-chain
 * TokenProfile - see lib/hooks/useTokenDiscovery.ts, which is the one place
 * that enriches on-chain TokenSummary/TokenDetail data with it) when one
 * exists, falling back to the deterministic prizeSkin(ticker) placeholder
 * gradient - the same one every token already showed before an image could
 * ever be uploaded - when there is none, or it fails to load. Never shows
 * both, and never a broken-image icon: a failed <img> load flips local
 * state to fall back to prizeSkin on the very same render pass a user would
 * otherwise see the browser's own broken-image glyph.
 *
 * The failure flag is reset by ADJUSTING STATE DURING RENDER (React's own
 * documented pattern for "reset derived state when a prop changes" - see
 * shouldResetImageFailure above for the actual condition), not inside a
 * useEffect: this avoids an extra commit+effect+re-render pass (which would
 * otherwise flash the stale prizeSkin fallback for one frame even after a
 * previously-broken image has been replaced with a working one) and keeps
 * useTokenDiscovery's own polling refetch (see its own docs) able to hand
 * this already-mounted component a new imageUrl for the same token without
 * a stale failure from the OLD url ever surviving onto the new one.
 *
 * Deliberately a plain <img>, not next/image: every imageUrl this ever
 * receives is a same-site upload (`/uploads/...`, served by
 * app/api/upload-image's own route - see lib/storage/filesystem.ts), never
 * a remote domain, so next/image's remotePatterns configuration has nothing
 * to add here and would be pure overhead for a URL that's always
 * same-origin. `object-cover` keeps the real image's own aspect ratio
 * correct (crops, never stretches) inside the same fixed square every
 * prizeSkin call site already sized via `className` - this component
 * changes nothing about layout, only which visual fills that square.
 *
 * `className` carries the FULL existing sizing/rounding/shadow string each
 * call site already used for its prizeSkin <span> (e.g.
 * "h-[30px] w-[30px] flex-none rounded-lg") - passed through unchanged to
 * whichever element this renders, so no call site's own layout needs to
 * change to adopt this.
 */
export function TokenAvatar({
  ticker,
  imageUrl,
  className,
}: {
  ticker: string;
  imageUrl?: string | null;
  className: string;
}) {
  const [prevImageUrl, setPrevImageUrl] = useState(imageUrl);
  const [failed, setFailed] = useState(false);

  if (shouldResetImageFailure(prevImageUrl, imageUrl)) {
    setPrevImageUrl(imageUrl);
    setFailed(false);
  }

  const showImage = Boolean(imageUrl) && !failed;

  if (showImage) {
    return (
      // eslint-disable-next-line @next/next/no-img-element -- always a same-site upload, see this component's own docs above
      <img src={imageUrl!} alt="" onError={() => setFailed(true)} className={`${className} object-cover`} />
    );
  }

  return <span aria-hidden className={className} style={{ background: prizeSkin(ticker) }} />;
}
