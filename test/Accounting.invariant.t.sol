// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {PoolDriver} from "./helpers/PoolDriver.sol";
import {StopLossHook} from "../src/StopLossHook.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract OrderHandler is Test {
    using StateLibrary for IPoolManager;
    StopLossHook hook;
    IPoolManager manager;
    PoolDriver driver;
    PoolKey key;
    PoolId poolId;

    constructor(StopLossHook h, IPoolManager m, PoolDriver d, PoolKey memory k) {
        hook = h;
        manager = m;
        driver = d;
        key = k;
        poolId = k.toId();
        IERC20(Currency.unwrap(k.currency1)).approve(address(h), type(uint256).max);
    }

    receive() external payable {}

    function place(uint128 amount, uint8 levels) external {
        (, int24 tick,,) = manager.getSlot0(poolId);
        int24 trigger = (TickBitmap.compress(tick, 60) + int24(uint24(bound(levels, 1, 8)))) * 60;
        amount = uint128(bound(amount, 1 ether, 1e24));
        if (IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this)) < amount) return;
        hook.placeOrder(key, trigger, amount);
    }

    function cancel(uint256 seed) external {
        if (hook.nextOrderId() == 1) return;
        uint256 id = bound(seed, 1, hook.nextOrderId() - 1);
        StopLossHook.Order memory o = hook.order(id);
        if (o.cancelled || o.claimed || hook.epoch(poolId, o.triggerTick, o.epoch).executed) return;
        hook.cancel(id);
    }

    function claim(uint256 seed) external {
        if (hook.nextOrderId() == 1) return;
        uint256 id = bound(seed, 1, hook.nextOrderId() - 1);
        StopLossHook.Order memory o = hook.order(id);
        if (o.cancelled || o.claimed || !hook.epoch(poolId, o.triggerTick, o.epoch).executed) return;
        hook.claim(id);
    }

    function execute(uint8 maximum) external {
        hook.execute(key, bound(maximum, 1, 5));
    }

    function movePrice(int24 target) external {
        target = int24(bound(int256(target), -3000, 3000));
        (uint160 price, int24 tick,,) = manager.getSlot0(poolId);
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        if (target == tick || price == limit) return;
        driver.swap(key, SwapParams(limit < price, -int256(1e26), limit));
    }
}

contract AccountingInvariantTest is HookFixture {
    OrderHandler handler;

    function setUp() public {
        _deploy();
        _seed(0, -12000, 12000, LIQUIDITY);
        handler = new OrderHandler(hook, manager, driver, key);
        token.transfer(address(handler), 1e26);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.place.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.execute.selector;
        selectors[4] = handler.movePrice.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_custodyEqualsOpenOrdersPlusUnclaimedEpochAssetsIncludingDust() public view {
        uint256 stopLiability;
        uint256 ethLiability;
        uint256 last = hook.nextOrderId();
        for (uint256 i = 1; i < last; ++i) {
            StopLossHook.Order memory o = hook.order(i);
            StopLossHook.Epoch memory e = hook.epoch(poolId, o.triggerTick, o.epoch);
            if (!e.executed) {
                if (!o.cancelled) stopLiability += o.amount;
                continue;
            }
            bool counted;
            for (uint256 j = 1; j < i; ++j) {
                StopLossHook.Order memory previous = hook.order(j);
                if (previous.triggerTick == o.triggerTick && previous.epoch == o.epoch) {
                    counted = true;
                    break;
                }
            }
            if (!counted) {
                stopLiability += e.unsold - e.claimedStop;
                ethLiability += e.ethOut - e.claimedEth;
                assertLe(e.unsold, e.amount);
                assertLt(o.epoch, hook.openEpoch(poolId, o.triggerTick));
            }
        }
        assertEq(token.balanceOf(address(hook)), stopLiability);
        assertEq(manager.balanceOf(address(hook), 0), ethLiability);
        assertEq(address(hook).balance, 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function invariant_bitmapAgreesWithOpenEpochAmounts() public view {
        for (uint256 i = 1; i < hook.nextOrderId(); ++i) {
            StopLossHook.Order memory o = hook.order(i);
            (int16 word, uint8 bit) = TickBitmap.position(o.triggerTick / 60);
            bool active = hook.activeTicks(poolId, word) & (uint256(1) << bit) != 0;
            assertEq(active, hook.openAmount(poolId, o.triggerTick) != 0);
        }
    }
}
