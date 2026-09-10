"use client";

import { WagmiAdapter } from "@reown/appkit-adapter-wagmi";
import { createAppKit, useAppKit } from "@reown/appkit/react";
import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { robinhoodChain } from "./chain";
import { env } from "./env";

// Wagmi itself needs SOME project id string to construct its adapter, even
// when Reown/AppKit's own wallet-connect features are disabled - this value
// is never sent anywhere unless createAppKit() below actually runs, which it
// deliberately does not when unconfigured (see below).
const projectId = env.reownProjectId ?? "00000000000000000000000000000000";

const wagmiAdapter = new WagmiAdapter({
  networks: [robinhoodChain],
  projectId,
  ssr: true,
});

// createAppKit() fetches remote project config from Reown's own API as part
// of initialization - this happens for ANY project id, real or not. Calling
// it with a placeholder id (as this file used to, unconditionally) sends a
// real network request that Reown's servers correctly reject with 403 for an
// unregistered id - that is real production log noise, not a sandbox
// artifact, and it doesn't stop happening just because the id is a
// placeholder. The fix is to only call it when a real project id exists.
if (env.reownProjectId) {
  createAppKit({
    adapters: [wagmiAdapter],
    networks: [robinhoodChain],
    projectId,
    metadata: {
      name: "CLOG",
      description: "Launch a meme. Own the ticker. Win the hour.",
      url: "https://clog.run",
      icons: ["https://clog.run/icon.png"],
    },
    features: {
      analytics: false,
    },
  });
}

// useAppKit() throws "Please call createAppKit before using..." if
// createAppKit() was never called above. Rather than call the hook
// conditionally (which both violates the rules of hooks and gets correctly
// flagged by eslint-plugin-react-hooks), its ENTIRE OWNING COMPONENT is
// conditionally rendered instead - a component that mounts or doesn't is the
// standard, lint-clean way to make a hook's use conditional. This bridge
// component's only job is publishing AppKit's real open() function to the
// module-level binding below, which useWalletAccount() reads directly rather
// than calling the hook itself.
let publishedOpen: (() => void) | null = null;

function AppKitBridge() {
  const { open } = useAppKit();
  useEffect(() => {
    publishedOpen = open;
    return () => {
      publishedOpen = null;
    };
  }, [open]);
  return null;
}

/** Opens the real Reown connect modal if AppKit was initialized; a safe
 * no-op otherwise (see lib/web3/env.ts's isWalletConfigured, which is what
 * every caller should check before deciding whether to offer this at all). */
export function openWalletModal() {
  publishedOpen?.();
}

export function Web3Provider({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={wagmiAdapter.wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        {env.reownProjectId && <AppKitBridge />}
        {children}
      </QueryClientProvider>
    </WagmiProvider>
  );
}
