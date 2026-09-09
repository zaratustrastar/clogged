"use client";

import { useCallback, useEffect, useState } from "react";
import type { Address } from "@/lib/types";

// TODO (live wiring): replace this entire hook body with:
//
//   import { useAccount, useConnect, useDisconnect } from "wagmi";
//   import { injected } from "wagmi/connectors";
//
//   export function useWalletAccount() {
//     const { address, isConnected } = useAccount();
//     const { connect } = useConnect();
//     const { disconnect } = useDisconnect();
//     return {
//       address: address ?? null,
//       isConnected,
//       connect: () => connect({ connector: injected() }),
//       disconnect,
//     };
//   }
//
// and wrap the app root in <WagmiProvider config={wagmiConfig}> +
// <QueryClientProvider> (see lib/contracts/wagmiConfig.ts for the config
// this hook is designed to slot into).
//
// Until then, this keeps a fake connected address in memory so every screen
// that depends on "is a wallet connected" is fully clickable and testable.

const DEMO_ADDRESS: Address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976";

interface WalletState {
  address: Address | null;
  isConnected: boolean;
  connect: () => void;
  disconnect: () => void;
}

let listeners: Array<(a: Address | null) => void> = [];
let currentAddress: Address | null = null;

function setGlobalAddress(a: Address | null) {
  currentAddress = a;
  listeners.forEach((l) => l(a));
}

export function useWalletAccount(): WalletState {
  const [address, setAddress] = useState<Address | null>(currentAddress);

  useEffect(() => {
    listeners.push(setAddress);
    return () => {
      listeners = listeners.filter((l) => l !== setAddress);
    };
  }, []);

  const connect = useCallback(() => setGlobalAddress(DEMO_ADDRESS), []);
  const disconnect = useCallback(() => setGlobalAddress(null), []);

  return { address, isConnected: address !== null, connect, disconnect };
}
