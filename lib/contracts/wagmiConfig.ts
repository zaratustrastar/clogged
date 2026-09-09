// TODO (live wiring): this file is intentionally not imported anywhere yet
// (see lib/hooks/useWalletAccount.ts, which currently uses a demo address
// instead). To go live:
//
//   1. `npm install wagmi viem @tanstack/react-query` (already in
//      package.json).
//   2. Define Robinhood Chain as a wagmi `Chain` object (id, name, native
//      currency, RPC URLs) once those details are finalized.
//   3. Uncomment the config below, fill in a WalletConnect project ID if
//      WalletConnect support is wanted alongside injected wallets.
//   4. Wrap the app root (app/layout.tsx) in:
//        <WagmiProvider config={wagmiConfig}>
//          <QueryClientProvider client={queryClient}>
//            {children}
//          </QueryClientProvider>
//        </WagmiProvider>
//   5. Swap lib/hooks/useWalletAccount.ts for the real wagmi-backed version
//      (the replacement code is already sketched in that file's own
//      comment).
//
// import { http, createConfig } from "wagmi";
// import { injected, walletConnect } from "wagmi/connectors";
//
// const robinhoodChain = {
//   id: ROBINHOOD_CHAIN_ID,
//   name: "Robinhood Chain",
//   nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
//   rpcUrls: { default: { http: ["https://REPLACE_WITH_REAL_RPC"] } },
// } as const;
//
// export const wagmiConfig = createConfig({
//   chains: [robinhoodChain],
//   connectors: [
//     injected(),
//     walletConnect({ projectId: "REPLACE_WITH_WALLETCONNECT_PROJECT_ID" }),
//   ],
//   transports: {
//     [robinhoodChain.id]: http(),
//   },
// });

export {};
