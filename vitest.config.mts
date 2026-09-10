import { defineConfig } from "vitest/config";
import path from "node:path";

export default defineConfig({
  resolve: {
    alias: {
      "@": import.meta.dirname,
      // "server-only" throws unconditionally unless imported through
      // Next.js's own bundler, which sets a special "react-server"
      // condition it checks for. Vitest runs plain Node, so it always
      // throws here - aliasing it to a no-op lets tests exercise the real
      // server-side modules (pool.ts, PostgresTokenProfileStore.ts, r2.ts)
      // directly, which is the whole point of these tests.
      "server-only": path.join(import.meta.dirname, "test/mocks/server-only-noop.ts"),
    },
  },
  test: {
    environment: "node",
    // contracts/ is a completely separate Foundry project with its own
    // node_modules (for the Chainlink packages) - without this, vitest's
    // default file discovery scans into those npm packages' own bundled
    // test files, which have nothing to do with this frontend's suite.
    // Same exclusion this repo already applies via tsconfig.json,
    // .eslintrc.json, and .vercelignore.
    exclude: ["**/node_modules/**", "**/contracts/**", "**/.next/**"],
  },
});
