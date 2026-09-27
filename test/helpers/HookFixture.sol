// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {STOP} from "../../src/STOP.sol";
import {StopLossHook} from "../../src/StopLossHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {PoolDriver} from "./PoolDriver.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    STOP internal token;
    IPoolManager internal manager;
    StopLossHook internal hook;
    PoolDriver internal driver;
    PoolKey internal key;
    PoolId internal poolId;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint128 internal constant LIQUIDITY = 1e24;

    function _deploy() internal {
        token = new STOP();
        manager = IPoolManager(address(new PoolManager(address(this))));
        bytes memory code = abi.encodePacked(type(StopLossHook).creationCode, abi.encode(manager));
        bytes32 codeHash = keccak256(code);
        for (uint256 i; i < 200_000; ++i) {
            address predicted = address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), codeHash)))
                )
            );
            if (!HookFlags.matches(predicted, HookFlags.STOP_LOSS)) continue;
            hook = new StopLossHook{salt: bytes32(i)}(manager);
            break;
        }
        require(address(hook) != address(0), "salt search exhausted");
        driver = new PoolDriver(manager);
        vm.deal(address(driver), 1e30);
        token.transfer(address(driver), 5e26);
        token.transfer(alice, 1e26);
        token.transfer(bob, 1e26);
        vm.prank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.prank(bob);
        token.approve(address(hook), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(hook));
        poolId = key.toId();
    }

    function _seed(int24 openingTick, int24 lower, int24 upper, uint128 liquidity) internal {
        manager.initialize(key, TickMath.getSqrtPriceAtTick(openingTick));
        driver.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, int256(uint256(liquidity)), bytes32(0))
        );
    }

    function _place(address owner, int24 trigger, uint128 amount) internal returns (uint256 id) {
        vm.prank(owner);
        return hook.placeOrder(key, trigger, amount);
    }

    function _toTick(int24 target) internal returns (BalanceDelta) {
        (, int24 tick,,) = manager.getSlot0(poolId);
        return driver.swap(key, SwapParams(target < tick, -int256(1e26), TickMath.getSqrtPriceAtTick(target)));
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }
}
