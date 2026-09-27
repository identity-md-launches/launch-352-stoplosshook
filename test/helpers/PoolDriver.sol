// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only funded router. Exercises real unlock, swap and settlement flows.
contract PoolDriver is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta)
    {
        return BalanceDelta.wrap(
            abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params))), (int256))
        );
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta) {
        return
            BalanceDelta.wrap(
                abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (int256))
            );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool add, PoolKey memory key, bytes memory payload) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (add) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        } else {
            delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
            // The hook must settle its own balances before control returns to this router.
            require(manager.currencyDelta(address(key.hooks), key.currency0) == 0, "hook ETH debt");
            require(manager.currencyDelta(address(key.hooks), key.currency1) == 0, "hook STOP debt");
        }
        require(manager.currencyDelta(address(this), key.currency0) == delta.amount0(), "router ETH delta");
        require(manager.currencyDelta(address(this), key.currency1) == delta.amount1(), "router STOP delta");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        // Inspect transient accounting while the unlock is still live, before the manager relocks.
        require(manager.currencyDelta(address(this), key.currency0) == 0, "unsettled router ETH");
        require(manager.currencyDelta(address(this), key.currency1) == 0, "unsettled router STOP");
        require(manager.getNonzeroDeltaCount() == 0, "unsettled pool deltas");
        return abi.encode(BalanceDelta.unwrap(delta));
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta > 0) manager.take(currency, address(this), uint128(delta));
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            if (currency.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        }
    }
}
