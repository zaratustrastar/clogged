"use client";

import { useAccount, useDisconnect } from "wagmi";
import { openWalletModal } from "@/lib/web3/Web3Provider";
import { isWalletConfigured } from "@/lib/web3/env";

/** Real wallet connection state, via wagmi (reading the connection Reown
 * AppKit establishes) - replaces the earlier in-memory demo toggle. */
export function useWalletAccount() {
  const { address, isConnected, chainId } = useAccount();
  const { disconnect } = useDisconnect();

  return {
    address: address ?? null,
    isConnected,
    chainId,
    connect: () => {
      if (isWalletConfigured) openWalletModal();
    },
    disconnect: () => disconnect(),
  };
}
