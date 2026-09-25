import type { Metadata, Viewport } from "next";
import { MachineHeader } from "@/components/layout/MachineHeader";
import { BasePlate } from "@/components/layout/BasePlate";
import { PublicLaunchGate } from "@/components/layout/PublicLaunchGate";
import { Web3Provider } from "@/lib/web3/Web3Provider"; // real path - handoff assumed @/components/providers/Web3Provider, which does not exist
import { env } from "@/lib/web3/env";
import "./globals.css";

const SITE_DESCRIPTION = "Launch a ticker, qualify it, and let the claw pick. Verifiably random draws onchain.";

export const metadata: Metadata = {
  // Required for Open Graph/Twitter images below to resolve to absolute
  // URLs - without it, Next.js silently falls back to
  // http://localhost:3000, which would be wrong (and logs a build warning)
  // in any real deployment. Same env.appUrl (NEXT_PUBLIC_APP_URL) this
  // codebase already reads elsewhere for absolute URLs (see
  // app/api/ticker-metadata/[...slug]/route.ts's own baseUrl()) - a
  // metadata export has no request to fall back to per-request the way
  // that dynamic route can, so this falls back to the real production
  // origin directly instead.
  metadataBase: new URL(env.appUrl ?? "https://clog.run"),
  title: "CLOG",
  description: SITE_DESCRIPTION,
  // mark 1a "The Prize" - machine black #0B0A09 / prize cream #F2EADB, per
  // the asset pack's own README. favicon.ico carries both 16x16 and 32x32
  // frames (a multi-resolution .ico), so its own `sizes` attribute names
  // 32x32, the larger of the two, letting the SVG or the explicit 16x16 PNG
  // win for anywhere a browser can use them instead. `icons.icon` accepts
  // an array in Next's own Metadata type - all four entries render as
  // separate <link rel="icon"> tags, exactly what the README's own <head>
  // snippet asked for, just emitted through the App Router's metadata
  // system (this project's own existing convention, see the plain
  // `metadata` export above) rather than hand-written tags in this file's
  // JSX below.
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "32x32" },
      { url: "/favicon.svg", type: "image/svg+xml" },
      { url: "/favicon-16.png", sizes: "16x16", type: "image/png" },
      { url: "/favicon-32.png", sizes: "32x32", type: "image/png" },
    ],
    apple: "/apple-touch-icon.png",
  },
  manifest: "/site.webmanifest",
  // og-avatar-400.png (square, 400x400) is this asset pack's own social-
  // preview image - wired into both Open Graph and Twitter/X card metadata
  // so a shared clog.run link renders the mark rather than nothing. `card:
  // "summary"` (not "summary_large_image") matches a square image - the
  // large-image card expects a wide ~2:1 banner, which this asset isn't.
  openGraph: {
    title: "CLOG",
    description: SITE_DESCRIPTION,
    images: [{ url: "/og-avatar-400.png", width: 400, height: 400 }],
  },
  twitter: {
    card: "summary",
    title: "CLOG",
    description: SITE_DESCRIPTION,
    images: ["/og-avatar-400.png"],
  },
};

// themeColor lives in a separate `viewport` export, not `metadata`, as of
// Next.js 14 (this project's own installed version, per package.json) -
// putting it in `metadata` instead logs a build-time "unsupported metadata"
// warning and is silently dropped from the rendered page.
export const viewport: Viewport = {
  themeColor: "#0B0A09",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {/* Loaded via a standard <link>, not next/font/google, for the same
            reason the previous layout did: next/font/google fetches and
            self-hosts font files at BUILD time, which requires build-time
            network access to fonts.googleapis.com - not guaranteed in every
            build environment this project deploys from. A <link> fetches at
            request/render time in the browser instead. Same three typefaces
            the handoff specifies (Archivo Black / Archivo / Space Mono),
            same CSS variable names the Tailwind theme reads
            (--font-display/--font-body/--font-mono) - just a loading
            mechanism that doesn't depend on the build environment's network
            access. The runbook itself treats next/font/google as optional
            ("if you prefer self-hosting"); this keeps the existing,
            already-proven approach instead. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        {/* eslint-disable-next-line @next/next/no-page-custom-font -- this rule
            targets the Pages Router's per-page <Head>, which causes flashes
            between pages; this is the App Router's root layout, which wraps
            every route, so the font applies globally exactly as intended. */}
        <link
          href="https://fonts.googleapis.com/css2?family=Archivo+Black&family=Archivo:wght@400;500;600;700&family=Space+Mono:wght@400;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body
        className="bg-void font-body text-ink-100 antialiased"
        style={
          {
            "--font-display": "'Archivo Black', sans-serif",
            "--font-body": "Archivo, sans-serif",
            "--font-mono": "'Space Mono', monospace",
          } as React.CSSProperties
        }
      >
        {/* The gate wraps Web3Provider rather than sitting inside it, so that
            before launch NOTHING in the application subtree renders: no wallet
            provider, no MachineHeader, no protocol hooks. At T-0 the gate's own
            interval swaps the subtree in on the open page, with no refresh and
            no server restart. Route handlers under /api/... are untouched -
            a root layout does not wrap them. */}
        <PublicLaunchGate>
          <Web3Provider>
            <MachineHeader />
            <main>{children}</main>
            <BasePlate />
          </Web3Provider>
        </PublicLaunchGate>
      </body>
    </html>
  );
}
