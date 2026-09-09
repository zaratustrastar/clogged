// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MemeToken} from "../../src/MemeToken.sol";

/// @notice Minimal stand-in for BondingCurveClog, exposing only what RewardVault needs
/// (IHasToken.token()) plus a way to move tokens around for TWAB test scenarios, without
/// pulling in the full bonding-curve economics for tests that don't need them.
contract MockMarket {
    MemeToken public immutable token;

    constructor(string memory name_, string memory symbol_) {
        token = new MemeToken(name_, symbol_, address(this));
        token.setMarket(address(this)); // MockMarket acts as its own market, holding the full supply
    }

    function distribute(address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}
