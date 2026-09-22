// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface IERC20Probe {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SentinelLiquidityHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;
    address public immutable owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IPoolManager poolManager_, address owner_) {
        require(owner_ != address(0), "zero owner");
        poolManager = poolManager_;
        owner = owner_;
    }

    struct AddParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        address payer;
    }

    struct RemoveParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        address recipient;
    }

    event Added(int256 amount0, int256 amount1);
    event Removed(int256 amount0, int256 amount1);

    function addLiquidity(AddParams calldata params)
        external
        payable
        onlyOwner
        returns (int256 amount0, int256 amount1)
    {
        require(
            params.payer == owner,
            "payer must be the probe owner - funded only by the deployer's own assets"
        );
        require(
            params.liquidityDelta > 0,
            "addLiquidity requires a positive liquidityDelta"
        );

        bytes memory result =
            poolManager.unlock(
                abi.encode(uint8(0), abi.encode(params), params.payer)
            );

        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        amount0 = int256(delta.amount0());
        amount1 = int256(delta.amount1());

        emit Added(amount0, amount1);

        if (address(this).balance > 0) {
            (bool ok,) =
                params.payer.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    function removeLiquidity(RemoveParams calldata params)
        external
        onlyOwner
        returns (int256 amount0, int256 amount1)
    {
        require(
            params.recipient == owner,
            "recipient must be the probe owner - recovered assets always return to the deployer"
        );
        require(
            params.liquidityDelta < 0,
            "removeLiquidity requires a negative liquidityDelta"
        );

        bytes memory result =
            poolManager.unlock(
                abi.encode(uint8(1), abi.encode(params), address(0))
            );

        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        amount0 = int256(delta.amount0());
        amount1 = int256(delta.amount1());

        emit Removed(amount0, amount1);
    }

    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        require(msg.sender == address(poolManager), "not pool manager");

        (
            uint8 kind,
            bytes memory paramsBytes,
            address payerOrZero
        ) = abi.decode(data, (uint8, bytes, address));

        if (kind == 0) {
            AddParams memory p = abi.decode(paramsBytes, (AddParams));

            (BalanceDelta callerDelta,) =
                poolManager.modifyLiquidity(
                    p.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: p.tickLower,
                        tickUpper: p.tickUpper,
                        liquidityDelta: p.liquidityDelta,
                        salt: p.salt
                    }),
                    bytes("")
                );

            int128 ethOwed = -callerDelta.amount0();
            int128 tokOwed = -callerDelta.amount1();

            if (ethOwed > 0) {
                poolManager.sync(p.key.currency0);
                poolManager.settle{
                    value: uint256(int256(ethOwed))
                }();
            }

            if (tokOwed > 0) {
                address tokenAddr = Currency.unwrap(p.key.currency1);
                uint256 amount = uint256(int256(tokOwed));

                require(
                    IERC20Probe(tokenAddr).transferFrom(
                        payerOrZero,
                        address(this),
                        amount
                    ),
                    "token pull failed"
                );

                poolManager.sync(p.key.currency1);

                require(
                    IERC20Probe(tokenAddr).transfer(
                        address(poolManager),
                        amount
                    ),
                    "token transfer to pool manager failed"
                );

                poolManager.settle();
            }

            return abi.encode(callerDelta);
        } else {
            RemoveParams memory p =
                abi.decode(paramsBytes, (RemoveParams));

            (BalanceDelta callerDelta,) =
                poolManager.modifyLiquidity(
                    p.key,
                    IPoolManager.ModifyLiquidityParams({
                        tickLower: p.tickLower,
                        tickUpper: p.tickUpper,
                        liquidityDelta: p.liquidityDelta,
                        salt: p.salt
                    }),
                    bytes("")
                );

            int128 ethOut = callerDelta.amount0();
            int128 tokOut = callerDelta.amount1();

            if (ethOut > 0) {
                poolManager.take(
                    p.key.currency0,
                    p.recipient,
                    uint256(int256(ethOut))
                );
            }

            if (tokOut > 0) {
                poolManager.take(
                    p.key.currency1,
                    p.recipient,
                    uint256(int256(tokOut))
                );
            }

            return abi.encode(callerDelta);
        }
    }

    receive() external payable {}
}
