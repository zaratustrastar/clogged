"use client";

import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import { createAppKit } from "@reown/appkit/react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { robinhoodChain } from "./chain";
import { env } from "./env";

// A dummy, non-functional project ID lets wagmi/AppKit initialize without
// throwing when NEXT_PUBLIC_REOWN_PROJECT_ID isn't set yet (local dev,
// preview deploys before the real ID is added to Vercel). `isWalletConfigured`
// (env.ts) is what actually gates whether the UI offers to connect - this
// placeholder only prevents a hard crash on module load.
const projectId = env.reownProjectId ?? "00000000000000000000000000000000";

const wagmiAdapter = new WagmiAdapter({
  networks: [robinhoodChain],
  projectId,
  ssr: true,
});

// createAppKit() must run unconditionally (even with the placeholder id
// above): hooks like useAppKit()/useAppKitAccount() read internal state
// this call sets up, and throw "Please call createAppKit before using..."
// during render - including Next.js's static prerendering - if it was
// skipped. This does not itself make any network call or expose a working
// connect flow; every place that renders a connect affordance (WalletButton,
// the dashboard's connect button) separately checks `isWalletConfigured`
// before calling `open()`, so a real connection is never attempted with the
// placeholder id.
createAppKit({
  adapters: [wagmiAdapter],
  networks: [robinhoodChain],
  projectId,
  metadata: {
    name: "CLOG",
    description: "Launch a meme. Own the ticker. Win the hour.",
    url: "https://clogged.vercel.app",
    icons: ["https://clogged.vercel.app/icon.png"],
  },
  features: {
    analytics: false,
  },
});

export function Web3Provider({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={wagmiAdapter.wagmiConfig}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
}
