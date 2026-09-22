// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {ClogMarket} from "../../src-v4/ClogMarket.sol";
import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineRegistry} from "../../src-v4/genuine/ClogGenuineRegistry.sol";
import {ClogFourPositionMath} from "../../src-v4/genuine/ClogFourPositionMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

library Miner4 {
    uint160 constant FLAGS = uint160(0x2ACC);
    uint160 constant MASK = uint160((1 << 14) - 1);
    function find(Vm vm, address d, bytes32 h, uint256 n) internal pure returns (address, bytes32) {
        for (uint256 i = 0; i < n; i++) {
            bytes32 s = bytes32(i);
            address c = vm.computeCreate2Address(s, h, d);
            if (uint160(c) & MASK == FLAGS) return (c, s);
        }
        revert("no salt");
    }
}

contract RegistryLaunchTest is Test {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;
    address constant SAFE = 0x29DEf4F5429CAC1e364263C449A7aE791657d48F;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    ClogFourPositionMath geometry;
    ClogGenuineRegistry registry;
    TickerNFT nft;
    RewardVault vault;
    PoolSwapTest router;

    address multisig = makeAddr("ms");
    address deployer = makeAddr("dep");
    address launcher = makeAddr("launcher");
    address trader = makeAddr("tr");

    function setUp() public {
        vm.warp(1_700_000_000);
        manager = new PoolManager(address(this));
        nft = new TickerNFT("R", "R", deployer, "https://x/", multisig);
        geometry = new ClogFourPositionMath(ClogFourPositionMath.HhMode.HI);

        registry = new ClogGenuineRegistry(
            SAFE, address(nft), multisig, address(new NoopEligibility()), SEED, BUFFER
        );

        bytes32 h = keccak256(
            abi.encodePacked(
                type(ClogGenuineLiquidityHook).creationCode,
                abi.encode(IPoolManager(address(manager)), address(registry), geometry)
            )
        );
        (, bytes32 salt) = Miner4.find(vm, address(this), h, 500_000);
        hook = new ClogGenuineLiquidityHook{salt: salt}(
            IPoolManager(address(manager)), address(registry), geometry
        );
        vault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));

        vm.prank(deployer);
        nft.setRegistry(address(registry));
        router = new PoolSwapTest(IPoolManager(address(manager)));
    }

    function test_registryLaunch_feeAndState() public {
        MemeToken token = new MemeToken("REG", "REG", address(registry));

        uint256 safeBefore = SAFE.balance;
        uint256 regBefore = address(registry).balance;
        uint256 vaultBefore = address(vault).balance;

        vm.deal(launcher, 1 ether);
        uint256 g = gasleft();
        vm.prank(launcher);
        (uint256 tokenId, address market) = registry.launch{value: 0.002 ether}(address(token), 1);
        uint256 launchGas = g - gasleft();
        emit log_named_uint("GAS registry launch", launchGas);

        // exactly 0.002 ETH to the Safe, nothing retained anywhere else
        assertEq(SAFE.balance - safeBefore, 0.002 ether, "Safe must receive exactly 0.002 ETH");
        assertEq(address(registry).balance, regBefore, "Registry must retain 0");
        assertEq(address(vault).balance, vaultBefore, "WinnerPot must get 0 of the launch fee");

        // TickerNFT minted to the launcher
        assertEq(nft.ownerOf(tokenId), launcher, "NFT must go to the launcher");

        // zero protocol ETH, token-only SINGLE_BOUNDARY position
        assertEq(address(manager).balance, 0, "launch must require ZERO protocol ETH");
        assertGt(token.balanceOf(address(manager)), 0, "position must hold token");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PoolId pid = key.toId();
        assertEq(uint8(hook.geometryMode(pid)), 1, "must be SINGLE_BOUNDARY after launch");

        // canonical state
        ClogMarket m = ClogMarket(market);
        assertEq(m.re(), SEED, "re must be the virtual seed");
        assertEq(m.rt(), 1_800_000_000e18, "rt must be the buffered curve allocation");
        assertEq(m.physicalInventory(), 1_000_000_000e18, "full supply as inventory");
        assertEq(m.realETH(), 0, "no real ETH at launch");

        // and it trades
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        router.swap{value: 0.5 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.5 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertGt(token.balanceOf(trader), 0, "first buy must deliver tokens");
        assertEq(m.re() - m.realETH(), SEED, "invariant after first trade");
        assertEq(m.rt() - m.physicalInventory(), 800_000_000e18, "invariant after first trade");
    }

    function test_registryLaunch_wrongFeeReverts() public {
        MemeToken token = new MemeToken("R2", "R2", address(registry));
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        vm.expectRevert(ClogGenuineRegistry.WrongFee.selector);
        registry.launch{value: 0.001 ether}(address(token), 1);
    }
}
