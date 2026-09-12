#!/usr/bin/env bash
# Builds the real, official Uniswap/universal-router package (installed at lib/universal-router)
# as its OWN, isolated Foundry project, using its own unmodified remappings.txt - required
# because UniversalRouter.sol unconditionally inherits v2/v3 swap modules that transitively
# depend on the official @uniswap/v3-periphery npm package, which itself pins
# @openzeppelin/contracts@3.4.1-solc-0.7-2 (genuinely Solidity-0.7-only, confirmed directly).
# That's incompatible, in one compilation unit, with this project's own 0.8.24+ files and its
# own global @openzeppelin/contracts remapping - but NOT a defect in universal-router itself:
# building it in isolation, exactly as its own CI does, succeeds cleanly.
#
# This script builds that isolated artifact once and copies the compiled UniversalRouter.json
# into this project's own out/ directory (gitignored, like all forge build output) under a
# dedicated external-artifact path, so test/v4/ClogUniversalRouter.t.sol can deploy the real,
# unmodified, officially-compiled UniversalRouter bytecode via vm.deployCode - without ever
# importing its full source into this project's own compilation graph.
#
# Run this once before `forge test --match-contract ClogUniversalRouterTest` (and again any time
# lib/universal-router is updated). Requires npm dependencies for universal-router's own v2/v3
# modules - see the `npm install` step below, matching universal-router's own package.json pins.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"

if [ ! -d "lib/universal-router/node_modules/@uniswap/v2-core" ] || [ ! -d "lib/universal-router/node_modules/@uniswap/v3-core" ]; then
  echo "Installing universal-router's own npm dependencies (v2-core@1.0.1, v3-core@1.0.0)..."
  (cd lib/universal-router && npm install @uniswap/v2-core@1.0.1 @uniswap/v3-core@1.0.0 --no-save)
fi

echo "Building universal-router as its own isolated Foundry project..."
(cd lib/universal-router && forge build)

mkdir -p "$REPO_ROOT/out/UniversalRouterExternal.sol"
cp "lib/universal-router/out/UniversalRouter.sol/UniversalRouter.json" \
   "$REPO_ROOT/out/UniversalRouterExternal.sol/UniversalRouter.json"

echo "Building the real Permit2 as its own isolated project (its own pragma, exactly 0.8.17, is
incompatible in one compilation unit with this project's 0.8.24+ files; skipping its own
test/script files, which hit an unrelated forge-std version mismatch unrelated to Permit2.sol
itself)..."
(cd lib/v4-periphery/lib/permit2 && forge build --skip test --skip script)
mkdir -p "$REPO_ROOT/out/Permit2External.sol"
cp "lib/v4-periphery/lib/permit2/out/Permit2.sol/Permit2.json" \
   "$REPO_ROOT/out/Permit2External.sol/Permit2.json"

echo "Done. Real UniversalRouter artifact ready at out/UniversalRouterExternal.sol/UniversalRouter.json"
echo "Real Permit2 artifact ready at out/Permit2External.sol/Permit2.json"
