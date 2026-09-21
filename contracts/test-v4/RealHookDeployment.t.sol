// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ClogV4Hook} from "../src-v4/ClogV4Hook.sol";
import {ClogMarket} from "../src-v4/ClogMarket.sol";
import {MinimalMockToken} from "./mocks/MinimalMockToken.sol";
import {MockTickerNFT} from "../test/mocks/MockTickerNFT.sol";
import {RewardVault} from "../src/RewardVault.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @title Real CREATE2 hook deployment (mined salt) - no vm.etch anywhere in this file
/// @notice Every other test file in this profile uses vm.etch onto a manually-chosen address
///         (address(0x2088)) purely to iterate quickly once a valid flag-bit address is already
///         known - explicitly flagged throughout as a shortcut, with real deployment needing
///         actual CREATE2 mining. This file is that proof: HookMiner.find() searches for a real
///         salt, the hook is deployed for real via `new ClogV4Hook{salt: salt}(...)`, and the
///         resulting address is used for a complete, real launch + trade sequence - proving the
///         mined deployment isn't just an address with the right bits sitting inert, but a fully
///         functional hook indistinguishable from the vm.etch shortcut used everywhere else.
contract RealHookDeploymentTest is Test, IUnlockCallback {
    PoolManager manager;
    ClogV4Hook hook;
    ClogMarket market;
    MinimalMockToken token;
    MockTickerNFT tickerNFT;
    RewardVault rewardVault;
    PoolKey key;

    address tickerOwner = makeAddr("tickerOwner");
    address multisig = makeAddr("multisig");
    uint256 constant TICKER_TOKEN_ID = 1;
    uint256 constant VIRTUAL_ETH_SEED = 9 ether;
    uint256 constant BUFFER_MULTIPLIER_BPS = 20_000;
    uint256 constant PHYSICAL_TOKEN_SUPPLY = 1_000_000_000e18;

    bool private _depositing;

    function setUp() public {
        manager = new PoolManager(address(this));

        // ── REAL mining, not a hardcoded address ────────────────────────────────────────────
        bytes memory creationCodeWithArgs =
            abi.encodePacked(type(ClogV4Hook).creationCode, abi.encode(IPoolManager(address(manager)), address(this)));
        bytes32 initCodeHash = HookMiner.hashInitCode(creationCodeWithArgs);
        (address minedAddress, bytes32 salt) = HookMiner.find(vm, address(this), initCodeHash, 200_000);

        // Sanity: the mined address must actually have the exact required bits BEFORE anything
        // is deployed there at all - proves the search itself is correct, independent of the
        // deployment that follows.
        assertEq(uint160(minedAddress) & HookMiner.ALL_HOOK_MASK, HookMiner.REQUIRED_FLAGS, "sanity: the mined address's low 14 bits must exactly match the required hook permission flags before any deployment happens");

        // ── REAL CREATE2 deployment at that exact address, no vm.etch anywhere ──────────────
        ClogV4Hook deployed = new ClogV4Hook{salt: salt}(IPoolManager(address(manager)), address(this));
        assertEq(address(deployed), minedAddress, "the real CREATE2 deployment must land at EXACTLY the address HookMiner predicted - proves the init code hash and deployer used for mining matched the actual deployment exactly");
        hook = deployed;

        rewardVault = new RewardVault(address(this), address(manager), address(hook));
        hook.setRewardVault(address(rewardVault));

        tickerNFT = new MockTickerNFT();
        tickerNFT.setOwner(TICKER_TOKEN_ID, tickerOwner);

        token = new MinimalMockToken();
        market = new ClogMarket(address(hook), address(token), address(tickerNFT), TICKER_TOKEN_ID, multisig, VIRTUAL_ETH_SEED, BUFFER_MULTIPLIER_BPS);

        key = PoolKey({currency0: Currency.wrap(address(0)), currency1: Currency.wrap(address(token)), fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
        hook.registerMarket(key, address(market));
        manager.initialize(key, 79228162514264337593543950336);

        token.mint(address(market), PHYSICAL_TOKEN_SUPPLY);
        _depositing = true;
        manager.unlock(bytes(""));
        _depositing = false;

        vm.startPrank(address(market));
        manager.approve(address(hook), uint256(uint160(address(token))), type(uint256).max);
        manager.approve(address(hook), uint256(uint160(address(0))), type(uint256).max);
        vm.stopPrank();
    }

    struct SwapRequest {
        bool zeroForOne;
        int256 amountSpecified;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not pool manager");

        if (_depositing) {
            manager.sync(key.currency1);
            vm.prank(address(market));
            token.transfer(address(manager), PHYSICAL_TOKEN_SUPPLY);
            manager.settle();
            manager.mint(address(market), uint256(uint160(address(token))), PHYSICAL_TOKEN_SUPPLY);
            return bytes("");
        }

        SwapRequest memory req = abi.decode(data, (SwapRequest));
        BalanceDelta swapDelta = manager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: req.zeroForOne, amountSpecified: req.amountSpecified, sqrtPriceLimitX96: 4295128740}),
            bytes("")
        );
        int128 ethOwed = -swapDelta.amount0();
        manager.sync(key.currency0);
        manager.settle{value: uint256(int256(ethOwed))}();
        int128 tokenOwed = swapDelta.amount1();
        manager.take(key.currency1, address(this), uint256(int256(tokenOwed)));
        return abi.encode(swapDelta);
    }

    receive() external payable {}

    /// @notice The real proof: a REAL buy, through the REAL, CREATE2-mined-and-deployed hook -
    ///         not a permission-bit sanity check alone, but a fully functioning trade producing
    ///         the exact same class of result already proven exhaustively elsewhere in this
    ///         profile against the vm.etch shortcut.
    function test_realMinedHook_executesARealBuyCorrectly() public {
        uint256 buyAmount = 0.05 ether;
        vm.deal(address(this), buyAmount);

        uint256 preManagerEthBalance = address(manager).balance;
        bytes memory result = manager.unlock(abi.encode(SwapRequest({zeroForOne: true, amountSpecified: -int256(buyAmount)})));
        BalanceDelta swapDelta = abi.decode(result, (BalanceDelta));
        uint256 tokensOut = uint256(int256(swapDelta.amount1()));

        assertGt(tokensOut, 0, "the real, CREATE2-mined-and-deployed hook must deliver real tokens from a real buy, exactly like the vm.etch shortcut used everywhere else in this profile");
        assertEq(address(manager).balance, preManagerEthBalance + buyAmount, "PoolManager must physically hold the real ETH input, exactly as with every other test in this profile");
        assertEq(token.balanceOf(address(this)), tokensOut, "the buyer must hold real ERC20 tokens delivered by take()");

        // The conservation invariant, same as every other buy test in this profile.
        assertEq(
            manager.balanceOf(address(market), uint256(uint160(address(0)))),
            market.realETH() + market.pendingWithdrawals(tickerOwner) + market.pendingWithdrawals(multisig),
            "the conservation invariant must hold exactly for the real, mined-and-deployed hook too"
        );
    }
}
