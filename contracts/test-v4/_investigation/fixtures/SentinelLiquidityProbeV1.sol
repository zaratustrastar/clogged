// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SentinelLiquidityHelper} from "./SentinelLiquidityHelperV1.sol";

interface IERC20ProbeView {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract SentinelLiquidityProbe is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager constant POOL_MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    address constant CANARY_TOKEN =
        0xD9772c6Ac0811064C8b521fa8B1832ac81cD0DE8;

    address constant HOOK =
        0xB1232678cEBA3292e915AB834342aD869F042088;

    address constant DEPLOYER =
        0x234fA20a83a88Db61f894890df7749A3fAF4dAEa;

    uint256 constant EXPECTED_CHAIN_ID = 4663;

    address constant CREATE2_DEPLOYER =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    int256 constant SENTINEL_LIQUIDITY = 1_000;

    bytes32 constant SENTINEL_SALT =
        keccak256("CLOG_SENTINEL_LIQUIDITY_PROBE_V1");

    bytes32 constant HELPER_CREATE2_SALT =
        keccak256("CLOG_SENTINEL_PROBE_HELPER_V1");

    PoolKey internal key;

    function setUp() public {
        require(
            block.chainid == EXPECTED_CHAIN_ID,
            "wrong chain - refusing to proceed against the wrong network"
        );

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(CANARY_TOKEN),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        bytes32 expectedPoolId =
            0x09af728e82c1a106d67693d92f308ea330afc07aafcd9b9d8831b4c4b437851b;

        require(
            PoolId.unwrap(key.toId()) == expectedPoolId,
            "computed poolId does not match the given poolId - PoolKey fields are wrong"
        );

        require(
            CREATE2_DEPLOYER.code.length > 0,
            "deterministic deployment proxy not present on this chain - salted deployment address prediction would be wrong"
        );

        console2.log("=== Sentinel probe identity ===");
        console2.log("  deployer:", DEPLOYER);

        console2.log("  SENTINEL_SALT:");
        console2.logBytes32(SENTINEL_SALT);

        console2.log("  HELPER_CREATE2_SALT:");
        console2.logBytes32(HELPER_CREATE2_SALT);

        console2.log(
            "  predicted helper address:",
            _helperAddress()
        );
    }

    function _printState(string memory label) internal view {
        (uint160 sqrtPriceX96, int24 tick,,) =
            POOL_MANAGER.getSlot0(key.toId());

        uint128 liquidity =
            POOL_MANAGER.getLiquidity(key.toId());

        uint256 ethBal = DEPLOYER.balance;

        uint256 tokenBal =
            IERC20ProbeView(CANARY_TOKEN).balanceOf(DEPLOYER);

        console2.log("===", label, "===");

        console2.log(
            "  slot0.sqrtPriceX96:",
            sqrtPriceX96
        );

        console2.log("  slot0.tick:");
        console2.logInt(tick);

        console2.log(
            "  active liquidity:",
            liquidity
        );

        console2.log(
            "  deployer ETH balance (wei):",
            ethBal
        );

        console2.log(
            "  deployer CANARY balance (wei):",
            tokenBal
        );
    }

    function addSentinel() public {
        (uint160 sqrtPriceX96, int24 tick,,) =
            POOL_MANAGER.getSlot0(key.toId());

        require(
            sqrtPriceX96 == 79228162514264337593543950336,
            "unexpected pool price - refusing sentinel add"
        );
        require(
            tick == 0,
            "unexpected pool tick - refusing sentinel add"
        );
        require(
            POOL_MANAGER.getLiquidity(key.toId()) == 0,
            "active liquidity already nonzero - refusing sentinel add"
        );

        _printState("BEFORE add");

        vm.startBroadcast(DEPLOYER);

        SentinelLiquidityHelper helper =
            _getOrDeployHelper();

        console2.log(
            "  helper address:",
            address(helper)
        );

        require(
            IERC20ProbeView(CANARY_TOKEN).approve(
                address(helper),
                1_000
            ),
            "CANARY approve failed"
        );

        (int256 amount0, int256 amount1) =
            helper.addLiquidity{value: 1e12}(
                SentinelLiquidityHelper.AddParams({
                    key: key,
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: SENTINEL_LIQUIDITY,
                    salt: SENTINEL_SALT,
                    payer: DEPLOYER
                })
            );

        vm.stopBroadcast();

        console2.log(
            "  exact ETH contributed (wei):"
        );
        console2.logInt(-amount0);

        console2.log(
            "  exact CANARY contributed (wei):"
        );
        console2.logInt(-amount1);

        console2.log(
            "  position liquidity added:",
            uint256(SENTINEL_LIQUIDITY)
        );

        _printState("AFTER add");
    }

    function removeSentinel() public {
        _printState("BEFORE remove");

        address helperAddr = _helperAddress();

        require(
            helperAddr.code.length > 0,
            "helper not deployed - addSentinel must have run first"
        );

        SentinelLiquidityHelper helper =
            SentinelLiquidityHelper(payable(helperAddr));

        vm.startBroadcast(DEPLOYER);

        (int256 amount0, int256 amount1) =
            helper.removeLiquidity(
                SentinelLiquidityHelper.RemoveParams({
                    key: key,
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: -SENTINEL_LIQUIDITY,
                    salt: SENTINEL_SALT,
                    recipient: DEPLOYER
                })
            );

        vm.stopBroadcast();

        console2.log(
            "  exact ETH returned (wei):"
        );
        console2.logInt(amount0);

        console2.log(
            "  exact CANARY returned (wei):"
        );
        console2.logInt(amount1);

        _printState("AFTER remove");
    }

    function predictedHelperAddress()
        public
        view
        returns (address)
    {
        return _helperAddress();
    }

    function _helperAddress()
        internal
        view
        returns (address)
    {
        bytes memory creationCode =
            abi.encodePacked(
                type(SentinelLiquidityHelper).creationCode,
                abi.encode(POOL_MANAGER, DEPLOYER)
            );

        return _computeCreate2Address(
            HELPER_CREATE2_SALT,
            keccak256(creationCode),
            CREATE2_DEPLOYER
        );
    }

    function _getOrDeployHelper()
        internal
        returns (SentinelLiquidityHelper)
    {
        address predicted = _helperAddress();

        if (predicted.code.length > 0) {
            return SentinelLiquidityHelper(
                payable(predicted)
            );
        }

        SentinelLiquidityHelper helper =
            new SentinelLiquidityHelper{
                salt: HELPER_CREATE2_SALT
            }(
                POOL_MANAGER,
                DEPLOYER
            );

        require(
            address(helper) == predicted,
            "helper address mismatch"
        );

        return helper;
    }

    function _computeCreate2Address(
        bytes32 salt,
        bytes32 initCodeHash,
        address deployer
    )
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            deployer,
                            salt,
                            initCodeHash
                        )
                    )
                )
            )
        );
    }
}
