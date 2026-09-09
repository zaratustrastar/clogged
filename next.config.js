/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  images: {
    remotePatterns: [{ protocol: "https", hostname: "**" }],
  },
  webpack: (config) => {
    // @reown/appkit-adapter-wagmi pulls in @wagmi/connectors' optional
    // "baseAccount" connector, which we never instantiate (see
    // lib/web3/Web3Provider.tsx - only the injected/WalletConnect flow
    // AppKit sets up by default is used). That connector transitively
    // imports Coinbase's x402 payment SDK, which references packages that
    // aren't installed dependencies of this project and aren't needed for
    // anything CLOG does. Aliasing them to `false` tells webpack to treat
    // these specific imports as empty modules instead of failing the build
    // - safe because the code path that would use them is never executed.
    config.resolve.alias = {
      ...config.resolve.alias,
      "@x402/evm/exact/client": false,
      "@x402/core/client": false,
      "@x402/svm/exact/client": false,
      "@x402/evm": false,
      "@x402/core": false,
      "@x402/svm": false,
      // MetaMask SDK's React Native storage backend and WalletConnect
      // logger's optional pretty-printer - neither applies in a Next.js
      // web build; both are only reached by code paths this app never runs.
      "@react-native-async-storage/async-storage": false,
      "pino-pretty": false,
    };
    return config;
  },
};

module.exports = nextConfig;
