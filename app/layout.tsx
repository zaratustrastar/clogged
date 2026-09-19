import type { Metadata } from "next";
import { MachineHeader } from "@/components/layout/MachineHeader";
import { BasePlate } from "@/components/layout/BasePlate";
import { Web3Provider } from "@/lib/web3/Web3Provider"; // real path - handoff assumed @/components/providers/Web3Provider, which does not exist
import "./globals.css";

export const metadata: Metadata = {
  title: "CLOG",
  description: "Launch a ticker, qualify it, and let the claw pick. Verifiably random draws onchain.",
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
        <Web3Provider>
          <MachineHeader />
          <main>{children}</main>
          <BasePlate />
        </Web3Provider>
      </body>
    </html>
  );
}
