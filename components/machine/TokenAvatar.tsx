"use client";

import { useState } from "react";
import { prizeSkin } from "@/components/machine/Claw";

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
  const [failed, setFailed] = useState(false);
  const showImage = Boolean(imageUrl) && !failed;

  if (showImage) {
    return (
      // eslint-disable-next-line @next/next/no-img-element -- always a same-site upload, see this component's own docs above
      <img src={imageUrl!} alt="" onError={() => setFailed(true)} className={`${className} object-cover`} />
    );
  }

  return <span aria-hidden className={className} style={{ background: prizeSkin(ticker) }} />;
}
