// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only settlement adapter. Never part of the launch deployment.
contract PoolDriver is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) external returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, key, true, abi.encode(params))), (BalanceDelta));
    }

    function liquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        return abi.decode(
            manager.unlock(abi.encode(msg.sender, key, false, abi.encode(params))), (BalanceDelta, BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory result) {
        require(msg.sender == address(manager), "manager only");
        (address payer, PoolKey memory key, bool swapping, bytes memory params) =
            abi.decode(data, (address, PoolKey, bool, bytes));
        if (swapping) {
            result = abi.encode(manager.swap(key, abi.decode(params, (IPoolManager.SwapParams)), ""));
        } else {
            (BalanceDelta delta, BalanceDelta fees) =
                manager.modifyLiquidity(key, abi.decode(params, (IPoolManager.ModifyLiquidityParams)), "");
            result = abi.encode(delta, fees);
        }
        _settle(payer, key.currency0);
        _settle(payer, key.currency1);
    }

    function _settle(address payer, Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), uint256(-delta));
            require(manager.settle() == uint256(-delta), "settlement mismatch");
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }
}
