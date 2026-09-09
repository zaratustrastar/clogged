"use client";

import { isWalletConfigured } from "@/lib/web3/env";

export function WalletButton() {
  if (!isWalletConfigured) {
    return (
      <button
        disabled
        title="Wallet connect is not configured yet (missing NEXT_PUBLIC_REOWN_PROJECT_ID)"
        className="rounded border border-border-strong px-3 py-2 text-sm text-ink-faint opacity-50"
      >
        Connect wallet
      </button>
    );
  }

  // The Reown AppKit web component handles the full connect/disconnect/
  // account/network-switch UI itself - no custom wallet UI to build or
  // maintain. Registered by createAppKit() in Web3Provider.tsx.
  return <appkit-button balance="hide" size="md" />;
}
