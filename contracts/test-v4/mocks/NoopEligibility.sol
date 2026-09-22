// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice TEST-ONLY stand-in for EligibilityRegistry in unit tests that are not about
///         eligibility. Records call count so tests can still assert onTrade fired once per
///         trade. Eligibility-specific tests use the REAL src/EligibilityRegistry.sol.
contract NoopEligibility {
    uint256 public onTradeCalls;
    uint256 public lastTokenId;

    function onTrade(uint256 tokenId) external {
        onTradeCalls++;
        lastTokenId = tokenId;
    }
}
