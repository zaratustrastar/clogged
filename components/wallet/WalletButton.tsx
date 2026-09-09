"use client";

import { useWalletAccount } from "@/lib/hooks/useWalletAccount";
import { formatAddress } from "@/lib/format";
import { Button } from "@/components/ui/Button";

export function WalletButton() {
  const { address, isConnected, connect, disconnect } = useWalletAccount();

  if (isConnected && address) {
    return (
      <button
        onClick={disconnect}
        title="Disconnect"
        className="flex items-center gap-2 rounded border border-border-strong px-3 py-2 text-sm font-mono text-ink hover:border-danger/60 hover:text-danger"
      >
        <span className="h-1.5 w-1.5 rounded-full bg-cyan" />
        {formatAddress(address)}
      </button>
    );
  }

  return (
    <Button variant="secondary" size="md" onClick={connect}>
      Connect wallet
    </Button>
  );
}
