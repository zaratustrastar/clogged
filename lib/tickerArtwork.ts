/**
 * Canonical TickerNFT artwork. Conceptually closer to ENS than to meme art:
 * the NFT represents ownership of the ticker identity itself, not the meme.
 * Every ticker in the collection shares the same recognizable CLOG layout
 * (branding position, ticker placement, typography) with deterministic
 * per-ticker variation (background gradient, pattern) derived from a hash
 * of (ticker, tokenId) - never random, never AI-generated, never stored on
 * disk or in a database. The same inputs always produce byte-identical SVG
 * output.
 *
 * Deliberately separate from lib/tickerColor.ts, which drives the small
 * in-app TokenIcon and is keyed on ticker alone - this generator is keyed on
 * (ticker, tokenId) together and produces a full collection piece, not a UI
 * accent color.
 */

const GRADIENT_PALETTE: [string, string][] = [
  ["#0C2E2A", "#1FF0D4"], // cyan
  ["#2E2110", "#FFB238"], // gold
  ["#141C33", "#7DA6FF"], // blue
  ["#211A33", "#B98CFF"], // violet
  ["#1B2E1D", "#6BD98C"], // green
  ["#33201A", "#FF9F6B"], // orange
];

/** Escapes text for safe inclusion in SVG/XML - ticker strings can currently
 * only ever be A-Z on-chain (see TickerRegistry._normalize, which reverts on
 * anything else), so this is defense in depth rather than closing a
 * presently-reachable injection path, not a reason to skip it. */
export function escapeXml(input: string): string {
  return input
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/** A simple, fully deterministic string hash - same inputs always produce
 * the same output, across processes and over time (no Date.now(), no
 * Math.random(), nothing non-deterministic anywhere in this file). */
function seedFrom(ticker: string, tokenId: number): number {
  const input = `${ticker}:${tokenId}`;
  let hash = 0;
  for (let i = 0; i < input.length; i++) {
    hash = (hash * 31 + input.charCodeAt(i)) >>> 0;
  }
  return hash;
}

export function generateTickerArtwork(ticker: string, tokenId: number): string {
  const seed = seedFrom(ticker, tokenId);

  const [colorA, colorB] = GRADIENT_PALETTE[seed % GRADIENT_PALETTE.length];
  const angle = (seed >>> 8) % 360;
  const cx1 = 60 + ((seed >>> 2) % 380);
  const cy1 = 60 + ((seed >>> 6) % 380);
  const r1 = 40 + ((seed >>> 10) % 70);
  const cx2 = 60 + ((seed >>> 14) % 380);
  const cy2 = 60 + ((seed >>> 18) % 380);
  const r2 = 25 + ((seed >>> 22) % 50);

  const safeTicker = escapeXml(`$${ticker}`);
  const safeTokenLabel = escapeXml(`Ticker #${tokenId}`);

  return `<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500" viewBox="0 0 500 500">
  <defs>
    <linearGradient id="bg" gradientUnits="objectBoundingBox" gradientTransform="rotate(${angle} 0.5 0.5)">
      <stop offset="0%" stop-color="${colorA}"/>
      <stop offset="100%" stop-color="${colorB}"/>
    </linearGradient>
  </defs>
  <rect width="500" height="500" fill="url(#bg)"/>
  <circle cx="${cx1}" cy="${cy1}" r="${r1}" fill="rgba(255,255,255,0.08)"/>
  <circle cx="${cx2}" cy="${cy2}" r="${r2}" fill="rgba(255,255,255,0.06)"/>
  <text x="32" y="48" font-family="ui-sans-serif, system-ui, sans-serif" font-size="22" font-weight="700" letter-spacing="2" fill="rgba(255,255,255,0.82)">CLOG</text>
  <text x="250" y="270" font-family="ui-sans-serif, system-ui, sans-serif" font-size="60" font-weight="800" fill="#ffffff" text-anchor="middle">${safeTicker}</text>
  <text x="250" y="322" font-family="ui-sans-serif, system-ui, sans-serif" font-size="18" fill="rgba(255,255,255,0.75)" text-anchor="middle">${safeTokenLabel}</text>
</svg>`;
}
