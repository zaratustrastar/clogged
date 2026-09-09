"use client";

import { useAccount, useDisconnect } from "wagmi";
import { useAppKit } from "@reown/appkit/react";
import { isWalletConfigured } from "@/lib/web3/env";

/** Real wallet connection state, via wagmi (reading the connection Reown
 * AppKit establishes) - replaces the earlier in-memory demo toggle. */
export function useWalletAccount() {
  const { address, isConnected, chainId } = useAccount();
  const { disconnect } = useDisconnect();
  const { open } = useAppKit();

  return {
    address: address ?? null,
    isConnected,
    chainId,
    connect: () => {
      if (isWalletConfigured) open();
    },
    disconnect: () => disconnect(),
  };
}
