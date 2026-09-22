// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {ClogGenuineLiquidityHook} from "../../src-v4/genuine/ClogGenuineLiquidityHook.sol";
import {ClogGenuineRegistry} from "../../src-v4/genuine/ClogGenuineRegistry.sol";
import {ClogFourPositionMath} from "../../src-v4/genuine/ClogFourPositionMath.sol";
import {MemeToken} from "../../src/MemeToken.sol";
import {TickerNFT} from "../../src/TickerNFT.sol";
import {RewardVault} from "../../src/RewardVault.sol";
import {NoopEligibility} from "../mocks/NoopEligibility.sol";

/// @title RegistryAccessControl
/// @notice Proves the setV4Infrastructure hole is closed: previously ANY account could re-point
///         poolManager/hook/rewardVault, and because hook.setRewardVault is onlyRegistry that
///         allowed redirecting the WinnerPot to an attacker-controlled vault.
contract RegistryAccessControlTest is Test {
    address constant SAFE = 0x29DEf4F5429CAC1e364263C449A7aE791657d48F;
    uint256 constant SEED = 9 ether;
    uint256 constant BUFFER = 20_000;

    PoolManager manager;
    ClogGenuineLiquidityHook hook;
    ClogFourPositionMath geometry;
    ClogGenuineRegistry registry;
    TickerNFT nft;
    RewardVault vault;

    address multisig = makeAddr("ms");
    address deployer = makeAddr("dep");
    address attacker = makeAddr("attacker");
    address launcher = makeAddr("launcher");

    function setUp() public {
        manager = new PoolManager(address(this));
        nft = new TickerNFT("AC", "AC", deployer, "https://x/", multisig);
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
        bytes32 salt;
        for (uint256 i = 0; i < 500_000; i++) {
            address c = vm.computeCreate2Address(bytes32(i), h, address(this));
            if (uint160(c) & uint160((1 << 14) - 1) == uint160(0x2ACC)) { salt = bytes32(i); break; }
        }
        hook = new ClogGenuineLiquidityHook{salt: salt}(
            IPoolManager(address(manager)), address(registry), geometry
        );
        vault = new RewardVault(makeAddr("rm"), address(manager), address(hook));
    }

    function test_1_configuratorIsDeployer() public view {
        assertEq(registry.configurator(), address(this), "configurator must be the deployer");
    }

    function test_2_unauthorisedCannotConfigureBeforeInit() public {
        vm.prank(attacker);
        vm.expectRevert(ClogGenuineRegistry.NotConfigurator.selector);
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
    }

    function test_3_configuratorCanConfigureOnce() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        assertEq(address(registry.poolManager()), address(manager), "poolManager set");
        assertEq(address(registry.hook()), address(hook), "hook set");
        assertEq(registry.rewardVault(), address(vault), "vault set");
        assertEq(hook.rewardVault(), address(vault), "hook vault set");
    }

    function test_4_secondConfigurationByConfiguratorReverts() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        vm.expectRevert(ClogGenuineRegistry.AlreadyConfigured.selector);
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
    }

    /// @notice THE ORIGINAL EXPLOIT: redirect the WinnerPot after configuration.
    function test_5_attackerCannotRepointRewardVault() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        RewardVault evil = new RewardVault(attacker, address(manager), address(hook));

        vm.prank(attacker);
        vm.expectRevert(ClogGenuineRegistry.NotConfigurator.selector);
        registry.setV4Infrastructure(address(manager), address(hook), address(evil));

        assertEq(registry.rewardVault(), address(vault), "vault must be unchanged");
        assertEq(hook.rewardVault(), address(vault), "hook vault must be unchanged");
    }

    function test_6_attackerCannotRepointPoolManagerOrHook() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        vm.prank(attacker);
        vm.expectRevert(ClogGenuineRegistry.NotConfigurator.selector);
        registry.setV4Infrastructure(attacker, attacker, attacker);
        assertEq(address(registry.poolManager()), address(manager), "poolManager unchanged");
        assertEq(address(registry.hook()), address(hook), "hook unchanged");
    }

    /// @notice Even the configurator cannot reconfigure - no upgrade path exists.
    function test_7_configuratorCannotReconfigureLater() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        RewardVault other = new RewardVault(makeAddr("rm2"), address(manager), address(hook));
        vm.expectRevert(ClogGenuineRegistry.AlreadyConfigured.selector);
        registry.setV4Infrastructure(address(manager), address(hook), address(other));
    }

    function test_8_zeroAddressesRejected() public {
        vm.expectRevert(ClogGenuineRegistry.ZeroAddress.selector);
        registry.setV4Infrastructure(address(0), address(hook), address(vault));
        vm.expectRevert(ClogGenuineRegistry.ZeroAddress.selector);
        registry.setV4Infrastructure(address(manager), address(0), address(vault));
        vm.expectRevert(ClogGenuineRegistry.ZeroAddress.selector);
        registry.setV4Infrastructure(address(manager), address(hook), address(0));
    }

    /// @notice The normal launch path is unaffected by the fix.
    function test_9_normalLaunchStillWorks() public {
        registry.setV4Infrastructure(address(manager), address(hook), address(vault));
        vm.prank(deployer);
        nft.setRegistry(address(registry));

        MemeToken token = new MemeToken("AC", "AC", address(registry));
        uint256 safeBefore = SAFE.balance;
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (uint256 tokenId, address market) = registry.launch{value: 0.002 ether}(address(token), 1);

        assertEq(SAFE.balance - safeBefore, 0.002 ether, "0.002 ETH to Safe");
        assertEq(address(registry).balance, 0, "registry retains 0");
        assertEq(nft.ownerOf(tokenId), launcher, "NFT to launcher");
        assertTrue(market != address(0), "market deployed");
    }
}
