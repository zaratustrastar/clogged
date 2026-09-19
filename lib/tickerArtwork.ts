import { readFileSync } from "node:fs";
import path from "node:path";

/**
 * Canonical TickerNFT artwork - VERSIONED. See generateTickerArtworkV1/V2's
 * own docs below for what each version does and, critically, why both must
 * keep existing side by side forever rather than one replacing the other.
 *
 * Conceptually closer to ENS than to meme art either way: the NFT
 * represents ownership of the ticker identity itself, not the meme.
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

/** ═══════════════════════════════════════════════════════════════════════
 * V1 - the original generated-gradient collection look. Used by every
 * deployment that existed before the V2 claw-machine artwork was approved:
 * legacy HOOD and canary-v1. Their already-minted NFTs' metadata.image URLs
 * point at these exact deployments forever (immutable on-chain base URIs),
 * so whatever this function returns for a given (ticker, tokenId) today
 * must be what it returns for that same pair for as long as this app runs -
 * this function's own body must never change, only be called from fewer
 * places over time as new deployments move to V2. If you need to change the
 * V2 look, do it in generateTickerArtworkV2, never here.
 * ═══════════════════════════════════════════════════════════════════════ */
export function generateTickerArtworkV1(ticker: string, tokenId: number): string {
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

/** @deprecated Use generateTickerArtworkV1 explicitly (or V2, via
 * generateTickerArtworkForDeployment) - kept only so nothing importing the
 * old unversioned name breaks at once; every real call site in this repo
 * has already been updated to call a versioned function directly. */
export const generateTickerArtwork = generateTickerArtworkV1;

/** ═══════════════════════════════════════════════════════════════════════
 * V2 - the approved CLOG claw-machine artwork. One shared, approved raster
 * base (see V2_BASE_IMAGE_DATA_URI below) - preserved exactly, never
 * redesigned or regenerated here - with the ticker's own identity
 * overlaid, as SVG text, into the base image's own intentionally empty
 * plaque area. New for the V2 deployment only; legacy HOOD and canary-v1
 * keep using V1 forever (see generateTickerArtworkV1's own docs on why).
 * ═══════════════════════════════════════════════════════════════════════ */

/** The approved base artwork, read once at module load and cached in
 * memory for the life of the process - never re-read per request, and
 * never fetched over the network (an externally loaded nested image would
 * be exactly the kind of non-self-contained dependency the marketplace-
 * safety requirement here rules out). Re-encoded from the originally
 * approved 2048x2048 PNG to an 800x800 JPEG (quality 85): the source image
 * is fully opaque throughout (verified directly - its alpha channel's own
 * min/max are both 255, i.e. no pixel is ever partially or fully
 * transparent), so JPEG loses nothing the design actually uses, and at
 * marketplace thumbnail sizes 800x800 is already higher resolution than
 * will ever be displayed - this is a file-size optimization for a
 * self-contained, embedded data URI response, not a redesign of the
 * artwork: every pixel's own color is preserved, only the encoding and
 * the (visually lossless, at any real display size) resolution changed.
 */
const V2_BASE_IMAGE_PATH = path.join(process.cwd(), "lib/assets/ticker-nft-v2-base.jpg");
let cachedV2BaseImageDataUri: string | null = null;

function getV2BaseImageDataUri(): string {
  if (cachedV2BaseImageDataUri) return cachedV2BaseImageDataUri;
  const bytes = readFileSync(V2_BASE_IMAGE_PATH);
  cachedV2BaseImageDataUri = `data:image/jpeg;base64,${bytes.toString("base64")}`;
  return cachedV2BaseImageDataUri;
}

/** The base image is 800x800; the SVG viewBox matches it 1:1 so every
 * pixel coordinate measured directly against the base image (below) maps
 * onto the SVG canvas with no scaling arithmetic anywhere in this file. */
const V2_CANVAS_SIZE = 800;

/** The base artwork's own intentionally empty plaque area - measured
 * directly against the approved base image's real pixel content (scanning
 * for the dark plaque bar's actual boundaries), not guessed. The plaque
 * itself spans roughly y=[655,780]; PLAQUE_SAFE_* below is deliberately
 * inset from those real edges so text never touches the plaque's own
 * beveled border or the corner bolts visible in the artwork. */
const PLAQUE_SAFE_LEFT = 90;
const PLAQUE_SAFE_RIGHT = 710;
const PLAQUE_SAFE_WIDTH = PLAQUE_SAFE_RIGHT - PLAQUE_SAFE_LEFT; // 620
const PLAQUE_CENTER_X = (PLAQUE_SAFE_LEFT + PLAQUE_SAFE_RIGHT) / 2; // 400

const TICKER_LINE_BASELINE_Y = 712;
const TOKEN_LINE_BASELINE_Y = 756;
const TOKEN_LINE_FONT_SIZE = 24;

/** Same bold, condensed system-font stack for both overlay lines - no
 * externally referenced/loaded font file anywhere (the marketplace-safety
 * requirement this whole endpoint exists to satisfy): every one of these
 * names is either a real font already installed on essentially any
 * rendering device, or a generic family the renderer substitutes
 * automatically - never a @font-face, @import, or <link>. Visually chosen
 * to match the base artwork's own "CLOG" wordmark, a bold, tall,
 * condensed-grotesk display face. */
const OVERLAY_FONT_FAMILY = "'Arial Black', 'Arial Narrow', Impact, Arial, sans-serif";

/** Ticker length is 2-10 uppercase ASCII characters on-chain (TickerRegistry
 * enforces this at commit/reveal time - see MIN_TICKER_LENGTH/
 * MAX_TICKER_LENGTH), so "$" + ticker is 3-11 characters. Font size scales
 * down smoothly as the ticker gets longer, capped at a maximum that stays
 * visually proportionate to the plaque's own height (the plaque area is
 * ~125px tall, shared with the smaller "Ticker #N" line below it) - never
 * so large a short ticker looks oversized relative to the rest of the
 * artwork. The `textLength` attribute set alongside this (see
 * buildTickerLine below) is what actually GUARANTEES the rendered width
 * never exceeds the safe area regardless of the viewer's real font
 * metrics - this font-size formula only needs to get close, not be exact,
 * since textLength corrects for the gap between this estimate and
 * whatever the renderer's real glyph widths turn out to be. */
function tickerLineFontSize(tickerWithDollar: string): number {
  const maxFontSize = 68;
  // ~0.62x font-size per glyph is a reasonable average for a bold
  // condensed uppercase face - used only to pick a proportionate starting
  // size, not to guarantee the fit (textLength does that).
  const estimatedFontSizeToFillWidth = PLAQUE_SAFE_WIDTH / (tickerWithDollar.length * 0.62);
  return Math.min(maxFontSize, estimatedFontSizeToFillWidth);
}

/** Renders the $TICKER line with a `textLength`/`lengthAdjust` clamp so the
 * ticker NEVER visually overflows the plaque's safe area, regardless of
 * which font the actual viewer substitutes at render time (a marketplace
 * or wallet's own SVG renderer is never guaranteed to have the exact same
 * font metrics as any other) - this is what makes "ensure all valid ticker
 * lengths fit cleanly" a guarantee rather than a best-effort estimate. A
 * short ticker's own natural width at its chosen font-size is always under
 * the safe-area budget already, so clamping textLength to
 * min(safeWidth, naturalEstimatedWidth) never stretches a short ticker to
 * fill unused space - only ever compresses a longer one back down if it
 * would otherwise overflow. */
function buildTickerLine(tickerWithDollar: string): string {
  const fontSize = tickerLineFontSize(tickerWithDollar);
  const naturalEstimatedWidth = tickerWithDollar.length * fontSize * 0.62;
  const renderedWidth = Math.min(PLAQUE_SAFE_WIDTH, naturalEstimatedWidth);
  return `<text x="${PLAQUE_CENTER_X}" y="${TICKER_LINE_BASELINE_Y}" text-anchor="middle" textLength="${renderedWidth.toFixed(1)}" lengthAdjust="spacingAndGlyphs" font-family="${OVERLAY_FONT_FAMILY}" font-size="${fontSize.toFixed(1)}" font-weight="900" letter-spacing="1" fill="#F2EFEA">${escapeXml(tickerWithDollar)}</text>`;
}

/** "Ticker #<tokenId>" - a fixed, smaller size regardless of ticker length
 * (a token id can only ever grow the collection's public cap's own digit
 * count, never the multi-hundred-pixel range a 2-vs-10-character ticker
 * spans), but still textLength-clamped for the same never-overflow
 * guarantee, since a token id near the top of a very large collection cap
 * could in principle still run long. */
function buildTokenIdLine(tokenId: number): string {
  const label = `TICKER #${tokenId}`;
  const naturalEstimatedWidth = label.length * TOKEN_LINE_FONT_SIZE * 0.58;
  const renderedWidth = Math.min(PLAQUE_SAFE_WIDTH, naturalEstimatedWidth);
  return `<text x="${PLAQUE_CENTER_X}" y="${TOKEN_LINE_BASELINE_Y}" text-anchor="middle" textLength="${renderedWidth.toFixed(1)}" lengthAdjust="spacingAndGlyphs" font-family="${OVERLAY_FONT_FAMILY}" font-size="${TOKEN_LINE_FONT_SIZE}" font-weight="700" letter-spacing="3" fill="#9A9790">${escapeXml(label)}</text>`;
}

/** Generates V2 TickerNFT artwork: the approved claw-machine base image,
 * embedded directly as a data URI (no externally loaded nested image - the
 * whole response is one self-contained SVG document), with the ticker's
 * own identity overlaid as deterministic SVG text into the base artwork's
 * intentionally empty plaque area. Same (ticker, tokenId) always produces
 * byte-identical output - no randomness, no current timestamp, nothing
 * non-deterministic anywhere in this function (unlike V1, V2 doesn't even
 * vary its background per-token - the whole point of V2 is that every
 * token in the collection shares the identical approved base image,
 * distinguished only by its own plaque text).
 */
export function generateTickerArtworkV2(ticker: string, tokenId: number): string {
  const tickerWithDollar = `$${ticker}`;
  const baseImageDataUri = getV2BaseImageDataUri();

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${V2_CANVAS_SIZE}" height="${V2_CANVAS_SIZE}" viewBox="0 0 ${V2_CANVAS_SIZE} ${V2_CANVAS_SIZE}">
  <image x="0" y="0" width="${V2_CANVAS_SIZE}" height="${V2_CANVAS_SIZE}" href="${baseImageDataUri}"/>
  ${buildTickerLine(tickerWithDollar)}
  ${buildTokenIdLine(tokenId)}
</svg>`;
}

