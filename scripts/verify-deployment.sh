#!/usr/bin/env bash
# Read-only verification of deployments/robinhood-mainnet.json against the
# real, live chain - BOTH chains, since the deployed system spans Robinhood
# Chain and Arbitrum One. Makes ONLY eth_call/eth_getCode/eth_getBlockByNumber
# -style reads via `cast` - never sends a transaction, never needs a private
# key, on either chain.
#
# WHY THIS EXISTS: the addresses in deployments/robinhood-mainnet.json were
# supplied as configuration, not independently verified on-chain by whoever
# wrote that file - see docs/DEPLOYMENTS.md. This script performs the actual
# verification: confirms real contract code exists at every address on both
# chains, confirms the cross-contract getters each contract exposes actually
# point at each other exactly as the manifest claims (catching a copy-paste
# swap between two addresses, which "code exists" alone can never catch),
# confirms the Arbitrum wrapper's own VRF subscription/keyHash configuration
# matches the deployed canary's real VRF setup, and determines
# deploymentBlock from real chain data via binary search on TickerRegistry's
# own code presence - never guessed, never assumed to be "current block".
#
# Requires `cast` (part of Foundry - https://getfoundry.sh) and `jq`. Run
# wherever there is real RPC access to Robinhood Chain Mainnet AND Arbitrum
# One (the sandboxed environment used to prepare this script has neither -
# see this repo's own commit history / PR description for that caveat
# stated up front, not discovered after the fact).
#
# Usage:
#   ./scripts/verify-deployment.sh
#   ROBINHOOD_RPC_URL=https://your-provider/... ARBITRUM_RPC_URL=https://your-provider/... ./scripts/verify-deployment.sh

set -euo pipefail

ROBINHOOD_RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
ARBITRUM_RPC_URL="${ARBITRUM_RPC_URL:-https://arb1.arbitrum.io/rpc}"

MANIFEST="$(dirname "$0")/../deployments/robinhood-mainnet.json"
if [ ! -f "$MANIFEST" ]; then
  echo "FAIL: manifest not found at $MANIFEST"
  exit 1
fi

TICKER_REGISTRY=$(jq -r '.contracts.tickerRegistry' "$MANIFEST")
TICKER_NFT=$(jq -r '.contracts.tickerNFT' "$MANIFEST")
ELIGIBILITY_REGISTRY=$(jq -r '.contracts.eligibilityRegistry' "$MANIFEST")
ROUND_MANAGER=$(jq -r '.contracts.roundManager' "$MANIFEST")
REWARD_VAULT=$(jq -r '.contracts.rewardVault' "$MANIFEST")
CHAINLINK_PROVIDER=$(jq -r '.["$notReadByFrontend"].chainlinkRandomnessProvider' "$MANIFEST")
ARBITRUM_WRAPPER=$(jq -r '.["$notReadByFrontend"].arbitrumVrfWrapper' "$MANIFEST")
EXPECTED_VRF_SUBSCRIPTION_ID=$(jq -r '.["$notReadByFrontend"].arbitrumVrfSubscriptionId' "$MANIFEST")
EXPECTED_VRF_KEY_HASH=$(jq -r '.["$notReadByFrontend"].arbitrumVrfKeyHash' "$MANIFEST")
EXPECTED_CHAIN_ID=$(jq -r '.chainId' "$MANIFEST")

FAILURES=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS: $1"; }

echo "=== Chain IDs ==="
ACTUAL_ROBINHOOD_CHAIN_ID=$(cast chain-id --rpc-url "$ROBINHOOD_RPC_URL")
if [ "$ACTUAL_ROBINHOOD_CHAIN_ID" = "$EXPECTED_CHAIN_ID" ]; then
  pass "Robinhood RPC reports chain id $ACTUAL_ROBINHOOD_CHAIN_ID, matches manifest"
else
  fail "Robinhood RPC reports chain id $ACTUAL_ROBINHOOD_CHAIN_ID, manifest says $EXPECTED_CHAIN_ID"
fi
ACTUAL_ARBITRUM_CHAIN_ID=$(cast chain-id --rpc-url "$ARBITRUM_RPC_URL")
if [ "$ACTUAL_ARBITRUM_CHAIN_ID" = "42161" ]; then
  pass "Arbitrum RPC reports chain id $ACTUAL_ARBITRUM_CHAIN_ID (Arbitrum One)"
else
  fail "Arbitrum RPC reports chain id $ACTUAL_ARBITRUM_CHAIN_ID, expected 42161 (Arbitrum One)"
fi
echo ""

echo "=== Code exists (Robinhood Chain) ==="
for pair in "TickerRegistry:$TICKER_REGISTRY" "TickerNFT:$TICKER_NFT" "EligibilityRegistry:$ELIGIBILITY_REGISTRY" "RoundManager:$ROUND_MANAGER" "RewardVault:$REWARD_VAULT" "ChainlinkRandomnessProvider:$CHAINLINK_PROVIDER"; do
  name="${pair%%:*}"
  addr="${pair##*:}"
  code=$(cast code "$addr" --rpc-url "$ROBINHOOD_RPC_URL")
  if [ "$code" = "0x" ]; then
    fail "$name ($addr) has NO code on Robinhood Chain"
  else
    pass "$name ($addr) has code (${#code} hex chars)"
  fi
done
echo ""

echo "=== Code exists (Arbitrum One) ==="
code=$(cast code "$ARBITRUM_WRAPPER" --rpc-url "$ARBITRUM_RPC_URL")
if [ "$code" = "0x" ]; then
  fail "VRFWrapperOnArbitrum ($ARBITRUM_WRAPPER) has NO code on Arbitrum One"
else
  pass "VRFWrapperOnArbitrum ($ARBITRUM_WRAPPER) has code (${#code} hex chars)"
fi
echo ""

check_getter() {
  local label="$1" addr="$2" sig="$3" expected="$4" rpc="$5"
  local actual
  actual=$(cast call "$addr" "$sig" --rpc-url "$rpc" 2>&1 || echo "CALL_FAILED")
  # cast call returns a left-padded 32-byte address for `()(address)` sigs;
  # normalize both sides to lowercase, unpadded for comparison.
  actual_norm=$(echo "$actual" | tr 'A-F' 'a-f' | grep -oE '[0-9a-f]{40}$' || echo "")
  expected_norm=$(echo "$expected" | tr 'A-F' 'a-f' | sed 's/^0x//')
  if [ "$actual" = "CALL_FAILED" ]; then
    fail "$label: call failed entirely (function may not exist, or RPC error) - raw: $actual"
  elif [ "$actual_norm" = "$expected_norm" ]; then
    pass "$label matches ($expected)"
  else
    fail "$label MISMATCH: expected $expected, got 0x$actual_norm"
  fi
}

check_value() {
  # For non-address return values (uint256 subscription id, bytes32 keyHash)
  # - compared as-given by cast, not address-normalized.
  #
  # BUG FIXED: cast call's own uint256 output appends a human-readable
  # scientific-notation annotation for large values, e.g.
  # "83568090110973637554258631175012043155383488095251779152218551458964868806531 [8.356e76]"
  # - comparing this verbatim against the manifest's own plain decimal
  # value produced a false MISMATCH even when the actual integer was
  # identical. Strip a trailing " [...]" annotation (if present - bytes32
  # output never has one, so this is a harmless no-op there) before
  # comparing, so only the real integer token is ever compared.
  local label="$1" addr="$2" sig="$3" expected="$4" rpc="$5"
  local actual
  actual=$(cast call "$addr" "$sig" --rpc-url "$rpc" 2>&1 || echo "CALL_FAILED")
  actual_stripped=$(echo "$actual" | sed -E 's/ \[[0-9.e+]+\]$//')
  actual_norm=$(echo "$actual_stripped" | tr 'A-F' 'a-f')
  expected_norm=$(echo "$expected" | tr 'A-F' 'a-f')
  if [ "$actual" = "CALL_FAILED" ]; then
    fail "$label: call failed entirely (function may not exist, or RPC error) - raw: $actual"
  elif [ "$actual_norm" = "$expected_norm" ]; then
    pass "$label matches ($expected)"
  else
    fail "$label MISMATCH: expected $expected, got $actual"
  fi
}

echo "=== Cross-contract getters (Robinhood Chain) ==="
check_getter "TickerRegistry.eligibilityRegistry()" "$TICKER_REGISTRY" "eligibilityRegistry()(address)" "$ELIGIBILITY_REGISTRY" "$ROBINHOOD_RPC_URL"
check_getter "TickerRegistry.tickerNFT()" "$TICKER_REGISTRY" "tickerNFT()(address)" "$TICKER_NFT" "$ROBINHOOD_RPC_URL"
check_getter "TickerRegistry.winnerPot()" "$TICKER_REGISTRY" "winnerPot()(address)" "$REWARD_VAULT" "$ROBINHOOD_RPC_URL"
check_getter "TickerNFT.tickerRegistry()" "$TICKER_NFT" "tickerRegistry()(address)" "$TICKER_REGISTRY" "$ROBINHOOD_RPC_URL"
check_getter "RoundManager.engine()" "$ROUND_MANAGER" "engine()(address)" "$ELIGIBILITY_REGISTRY" "$ROBINHOOD_RPC_URL"
check_getter "RoundManager.randomnessProvider()" "$ROUND_MANAGER" "randomnessProvider()(address)" "$CHAINLINK_PROVIDER" "$ROBINHOOD_RPC_URL"
check_getter "RoundManager.rewardVault()" "$ROUND_MANAGER" "rewardVault()(address)" "$REWARD_VAULT" "$ROBINHOOD_RPC_URL"
check_getter "RewardVault.roundManager()" "$REWARD_VAULT" "roundManager()(address)" "$ROUND_MANAGER" "$ROBINHOOD_RPC_URL"
check_getter "EligibilityRegistry.roundManager()" "$ELIGIBILITY_REGISTRY" "roundManager()(address)" "$ROUND_MANAGER" "$ROBINHOOD_RPC_URL"
check_getter "ChainlinkRandomnessProvider.roundManager()" "$CHAINLINK_PROVIDER" "roundManager()(address)" "$ROUND_MANAGER" "$ROBINHOOD_RPC_URL"
check_getter "ChainlinkRandomnessProvider.wrapperOnArbitrum()" "$CHAINLINK_PROVIDER" "wrapperOnArbitrum()(address)" "$ARBITRUM_WRAPPER" "$ROBINHOOD_RPC_URL"
echo ""

echo "=== Cross-chain getters (Arbitrum One -> Robinhood Chain references) ==="
check_getter "VRFWrapperOnArbitrum.providerOnRobinhoodChain()" "$ARBITRUM_WRAPPER" "providerOnRobinhoodChain()(address)" "$CHAINLINK_PROVIDER" "$ARBITRUM_RPC_URL"
check_value "VRFWrapperOnArbitrum.subscriptionId()" "$ARBITRUM_WRAPPER" "subscriptionId()(uint256)" "$EXPECTED_VRF_SUBSCRIPTION_ID" "$ARBITRUM_RPC_URL"
check_value "VRFWrapperOnArbitrum.keyHash()" "$ARBITRUM_WRAPPER" "keyHash()(bytes32)" "$EXPECTED_VRF_KEY_HASH" "$ARBITRUM_RPC_URL"
echo ""

echo "=== Determining deploymentBlock (never guessed, never assumed to be 'current block') ==="
# BUG FIXED: the previous approach (binary search via cast code --block N)
# requires an ARCHIVE node - querying historical state at an arbitrary past
# block. Against the standard public Robinhood Chain RPC (not an archive
# endpoint), this failed outright with "metadata is not found, <block>" -
# confirmed directly from a real run, not a guess about node capability.
# Transaction RECEIPTS (unlike arbitrary historical state) are commonly
# retained even by non-archive nodes, so this now determines the block via
# the real TickerRegistry deployment transaction's own receipt instead -
# either a directly-supplied tx hash (most trustworthy - the actual
# protocol deployment transaction itself) or, failing that, the block
# explorer's own indexed contract-creation record cross-checked against a
# real receipt lookup on the RPC itself (never trusted from the explorer
# alone, unverified).
DEPLOYMENT_BLOCK=""

if [ -n "${TICKER_REGISTRY_DEPLOY_TX_HASH:-}" ]; then
  echo "Using supplied TICKER_REGISTRY_DEPLOY_TX_HASH: $TICKER_REGISTRY_DEPLOY_TX_HASH"
  receipt_block=$(cast receipt "$TICKER_REGISTRY_DEPLOY_TX_HASH" --rpc-url "$ROBINHOOD_RPC_URL" blockNumber 2>&1) || receipt_block=""
  if [ -n "$receipt_block" ] && [[ "$receipt_block" =~ ^[0-9]+$ ]]; then
    DEPLOYMENT_BLOCK="$receipt_block"
    pass "Resolved deploymentBlock $DEPLOYMENT_BLOCK from the real deployment transaction's own receipt"
  else
    fail "TICKER_REGISTRY_DEPLOY_TX_HASH was supplied but its receipt could not be read (raw: $receipt_block) - check the hash is correct and confirmed"
  fi
else
  echo "No TICKER_REGISTRY_DEPLOY_TX_HASH supplied - falling back to the block explorer's own indexed creation-transaction record."
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    explorer_response=$(curl -s "https://robinhoodchain.blockscout.com/api/v2/addresses/${TICKER_REGISTRY}" 2>&1) || explorer_response=""
    creation_tx_hash=$(echo "$explorer_response" | jq -r '.creation_tx_hash // .creator_tx_hash // empty' 2>/dev/null)
    if [ -n "$creation_tx_hash" ] && [ "$creation_tx_hash" != "null" ]; then
      echo "Block explorer reports creation tx: $creation_tx_hash - cross-checking against a real receipt lookup on the RPC itself (never trusted from the explorer alone)"
      receipt_block=$(cast receipt "$creation_tx_hash" --rpc-url "$ROBINHOOD_RPC_URL" blockNumber 2>&1) || receipt_block=""
      if [ -n "$receipt_block" ] && [[ "$receipt_block" =~ ^[0-9]+$ ]]; then
        DEPLOYMENT_BLOCK="$receipt_block"
        pass "Resolved deploymentBlock $DEPLOYMENT_BLOCK from the explorer-indexed creation tx, confirmed via a real RPC receipt lookup"
      else
        fail "Block explorer's creation_tx_hash ($creation_tx_hash) could not be confirmed via a real RPC receipt lookup (raw: $receipt_block)"
      fi
    else
      echo "Block explorer response did not include a creation transaction hash (raw response head: $(echo "$explorer_response" | head -c 200))"
    fi
  else
    echo "curl/jq not available - cannot query the block explorer's indexed data."
  fi
fi

if [ -z "$DEPLOYMENT_BLOCK" ]; then
  echo ""
  echo "COULD NOT DETERMINE deploymentBlock via any trustworthy source available to this script."
  echo "This is NOT treated as a deployment failure - it means neither a supplied tx hash nor the"
  echo "block explorer's indexed data resolved it. To fix: re-run with the real deployment"
  echo "transaction hash set explicitly:"
  echo "  TICKER_REGISTRY_DEPLOY_TX_HASH=0x... ./scripts/verify-deployment.sh"
  echo "Never fall back to guessing or to \"the current block\" - an unset deploymentBlock correctly"
  echo "keeps the frontend in its safe \"not configured\" state (see lib/web3/env.ts's"
  echo "isProtocolConfigured) rather than silently scanning from the wrong point."
else
  echo "VERIFIED_DEPLOYMENT_BLOCK=$DEPLOYMENT_BLOCK"
  echo "Set deployments/robinhood-mainnet.json's \"deploymentBlock\" to $DEPLOYMENT_BLOCK once this whole script reports zero failures."
fi
echo ""

echo "=== Summary ==="
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed (both chains, every cross-contract and cross-chain reference verified)."
  if [ -n "$DEPLOYMENT_BLOCK" ]; then
    echo "Fill in deploymentBlock ($DEPLOYMENT_BLOCK) before treating the manifest as fully verified."
  else
    echo "deploymentBlock could not be resolved this run (see above) - supply TICKER_REGISTRY_DEPLOY_TX_HASH and re-run before treating the manifest as fully verified."
  fi
  exit 0
else
  echo "$FAILURES check(s) FAILED. Do not treat this manifest as verified, do not point clog.run at it, until every failure above is understood and resolved."
  exit 1
fi
