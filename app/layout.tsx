import type { Metadata } from "next";
import { Navbar } from "@/components/layout/Navbar";
import { StatsTicker } from "@/components/layout/StatsTicker";
import { Footer } from "@/components/layout/Footer";
import "./globals.css";

export const metadata: Metadata = {
  title: "CLOG — Launch a meme. Win the hour.",
  description:
    "Launch a meme token for 0.002 ETH. Build enough real activity to qualify for the hourly draw — every qualified meme has equal odds.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        {/* Loaded via a standard <link>, not next/font/google: next/font fetches
            and self-hosts font files at BUILD time, which requires build-time
            network access to fonts.googleapis.com. A <link> fetches at
            request/render time in the browser instead — same three
            typefaces, same CSS variable names the rest of the app already
            expects, just a loading mechanism that doesn't depend on the
            build environment's network access. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        {/* eslint-disable-next-line @next/next/no-page-custom-font -- this rule
            targets the Pages Router's per-page <Head>, which causes flashes
            between pages; this is the App Router's root layout, which wraps
            every route, so the font applies globally exactly as intended. */}
        <link
          href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=Inter:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500;600&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="flex min-h-screen flex-col">
        <Navbar />
        <StatsTicker />
        <main className="flex-1">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
