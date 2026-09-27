// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {StopLossHook} from "../src/StopLossHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StopLossHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deploy();
        _seed(0, -12000, 12000, LIQUIDITY);
    }

    function test_permissionsAddressAndImmutableManager() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 192);
        assertEq(address(hook.poolManager()), address(manager));
        assertLe(address(hook).code.length, 24576);
    }

    function test_callbacksRejectForgedCallersAndUnsolicitedUnlock() public {
        SwapParams memory params = SwapParams(false, -int256(1 ether), TickMath.getSqrtPriceAtTick(60));
        vm.expectRevert();
        hook.beforeSwap(alice, key, params, "");
        vm.expectRevert();
        hook.afterSwap(alice, key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.unlockCallback("");
        vm.expectRevert(StopLossHook.UnexpectedUnlock.selector);
        vm.prank(address(manager));
        hook.unlockCallback(abi.encode(true, abi.encode(alice, 1 ether)));
    }

    function test_runtimeHasNoEscapeHatches() public view {
        bytes memory code = address(hook).code;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function test_placeCancelAndBitmapReuse() public {
        uint256 beforeBalance = token.balanceOf(alice);
        uint256 a = _place(alice, 60, 3 ether);
        uint256 b = _place(bob, 60, 7 ether);
        assertEq(hook.openAmount(poolId, 60), 10 ether);
        assertEq(hook.activeTicks(poolId, 0), 2);
        assertEq(hook.order(a).owner, alice);
        assertEq(hook.order(b).epoch, 0);
        vm.prank(alice);
        hook.cancel(a);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(hook.openAmount(poolId, 60), 7 ether);
        vm.prank(bob);
        hook.cancel(b);
        assertEq(hook.activeTicks(poolId, 0), 0);
        _place(alice, 60, 1 ether);
        assertEq(hook.activeTicks(poolId, 0), 2);
        assertEq(hook.openAmount(poolId, 60), 1 ether);
        vm.expectRevert(StopLossHook.InvalidOrder.selector);
        vm.prank(bob);
        hook.cancel(b);
    }

    function test_invalidOrderInputs() public {
        vm.expectRevert(StopLossHook.InvalidAmount.selector);
        _place(alice, 60, 1 ether - 1);
        vm.expectRevert(StopLossHook.InvalidAmount.selector);
        _place(alice, 60, type(uint128).max);
        int24[5] memory badTicks = [int24(0), -60, 61, 886080, -887280];
        for (uint256 i; i < badTicks.length; ++i) {
            vm.expectRevert(StopLossHook.InvalidTrigger.selector);
            _place(alice, badTicks[i], 1 ether);
        }
        vm.expectRevert();
        vm.prank(address(333));
        hook.placeOrder(key, 60, 1 ether);
        PoolKey memory bad = key;
        bad.fee = 500;
        vm.expectRevert(StopLossHook.InvalidPool.selector);
        hook.placeOrder(bad, 60, 1 ether);
        bad = key;
        bad.currency1 = Currency.wrap(address(555));
        vm.expectRevert(StopLossHook.InvalidPool.selector);
        hook.placeOrder(bad, 60, 1 ether);
        vm.expectRevert(StopLossHook.InvalidPool.selector);
        hook.execute(bad, 1);
        vm.expectRevert(StopLossHook.InvalidBucketCount.selector);
        hook.execute(key, 0);
        vm.expectRevert(StopLossHook.InvalidBucketCount.selector);
        hook.execute(key, 6);
    }

    function test_ownerOnlyCancelAndClaim() public {
        uint256 id = _place(alice, 60, 1 ether);
        vm.expectRevert(StopLossHook.NotOwner.selector);
        vm.prank(bob);
        hook.cancel(id);
        vm.expectRevert(StopLossHook.NotOwner.selector);
        vm.prank(bob);
        hook.claim(id);
        vm.expectRevert(StopLossHook.NotExecuted.selector);
        vm.prank(alice);
        hook.claim(id);
        vm.expectRevert(StopLossHook.InvalidOrder.selector);
        hook.cancel(999);
        _toTick(60);
        vm.expectRevert(StopLossHook.AlreadyExecuted.selector);
        vm.prank(alice);
        hook.cancel(id);
        vm.prank(alice);
        hook.claim(id);
        vm.expectRevert(StopLossHook.InvalidOrder.selector);
        vm.prank(alice);
        hook.claim(id);
    }

    function test_buysNeverTriggerAndBelowTriggerSellDoesNothing() public {
        _place(alice, 60, 10 ether);
        _toTick(-120);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        _toTick(59);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.execute(key, 5), 0);
        _toTick(60);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
    }

    function test_sellCrossingSevenLevelsExecutesFiveThenCatchUp() public {
        for (int24 i = 1; i <= 7; ++i) {
            _place(alice, i * 60, 1 ether);
        }
        uint256 start = gasleft();
        _toTick(420);
        emit log_named_uint("seller gas: router sell executing five buckets", start - gasleft());
        for (int24 i = 1; i <= 7; ++i) {
            assertEq(hook.epoch(poolId, i * 60, 0).executed, i <= 5);
        }
        assertEq(hook.execute(key, 1), 1);
        assertTrue(hook.epoch(poolId, 360, 0).executed);
        assertFalse(hook.epoch(poolId, 420, 0).executed);
        vm.prank(bob);
        assertEq(hook.execute(key, 5), 1);
        assertTrue(hook.epoch(poolId, 420, 0).executed);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_gapBeyondLimitDoesNotRevertAndRemainsCancellable() public {
        uint256 id = _place(alice, 60, 10 ether);
        _toTick(1320);
        assertGe(_tick(), 1320);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.execute(key, 5), 0);
        vm.prank(alice);
        hook.cancel(id);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_exactLimitSkippedAndCatchUpWhenPriceReturns() public {
        _place(alice, 60, 10 ether);
        _toTick(1260);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.execute(key, 5), 0);
        _toTick(1200);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.execute(key, 5), 1);
    }

    function test_buyAtInitializedLimitBoundaryDoesNotMakeExecuteRevert() public {
        driver.modifyLiquidity(key, ModifyLiquidityParams(1260, 2400, int256(uint256(LIQUIDITY)), bytes32(0)));
        _place(alice, 60, 10 ether);
        _toTick(1320);
        _toTick(1260);
        (uint160 price, int24 tick,,) = manager.getSlot0(poolId);
        assertEq(tick, 1259); // v4 records tickNext - 1 when crossing down.
        assertEq(price, TickMath.getSqrtPriceAtTick(1260));
        assertEq(hook.execute(key, 5), 0);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        _toTick(1250);
        assertEq(hook.execute(key, 5), 1);
    }

    function test_priceLimitLeavesUnsoldClaimable() public {
        uint256 id = _place(alice, 60, 1e25);
        _toTick(60);
        StopLossHook.Epoch memory e = hook.epoch(poolId, 60, 0);
        assertTrue(e.executed);
        assertGt(e.unsold, 0);
        assertGt(e.ethOut, 0);
        assertEq(_tick(), 1260);
        assertEq(token.balanceOf(address(hook)), e.unsold);
        assertEq(manager.balanceOf(address(hook), 0), e.ethOut);
        uint256 beforeStop = token.balanceOf(alice);
        uint256 beforeEth = alice.balance;
        vm.prank(alice);
        hook.claim(id);
        assertEq(alice.balance - beforeEth, e.ethOut);
        assertEq(token.balanceOf(alice) - beforeStop, e.unsold);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function test_claimRemainsSolventAfterLiquidityIsRemoved() public {
        uint256 id = _place(alice, 60, 1 ether);
        _toTick(60);
        uint256 proceeds = hook.epoch(poolId, 60, 0).ethOut;
        driver.modifyLiquidity(
            key, ModifyLiquidityParams(-12000, 12000, -int256(uint256(LIQUIDITY)), bytes32(0))
        );
        vm.prank(alice);
        hook.claim(id);
        assertEq(alice.balance, proceeds);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_ownSellsLeaveCrossedLevelsForExecute() public {
        _place(alice, 60, 1e22);
        _place(bob, 120, 1 ether);
        _toTick(60);
        assertGt(_tick(), 120);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
        assertFalse(hook.epoch(poolId, 120, 0).executed);
        assertEq(hook.execute(key, 5), 1);
    }

    function test_multiplePartialBucketsUseTheirOwnAscendingLimits() public {
        _place(alice, 60, 1e25);
        _place(bob, 120, 1e25);
        _place(alice, 180, 1e25);
        _toTick(180);
        assertEq(_tick(), 1380);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
        assertTrue(hook.epoch(poolId, 120, 0).executed);
        assertTrue(hook.epoch(poolId, 180, 0).executed);
    }

    function test_epochReuseDoesNotChangeOldEntitlement() public {
        uint256 a = _place(alice, 60, 2 ether);
        _toTick(60);
        StopLossHook.Epoch memory old = hook.epoch(poolId, 60, 0);
        _toTick(0);
        uint256 b = _place(bob, 60, 10 ether);
        assertEq(hook.order(b).epoch, 1);
        assertEq(hook.openEpoch(poolId, 60), 1);
        _toTick(60);
        vm.prank(alice);
        (uint256 eth,) = hook.claim(a);
        assertEq(eth, old.ethOut);
        assertEq(manager.balanceOf(address(hook), 0), hook.epoch(poolId, 60, 1).ethOut);
    }

    function testFuzz_proRataConservationAndDust(uint128 a, uint128 b, bool reverse) public {
        a = uint128(bound(a, 1 ether, 1e25));
        b = uint128(bound(b, 1 ether, 1e25));
        uint256 first = _place(alice, 60, a);
        uint256 second = _place(bob, 60, b);
        _toTick(60);
        StopLossHook.Epoch memory e = hook.epoch(poolId, 60, 0);
        uint256 ethAlice = uint256(e.ethOut) * a / (uint256(a) + b);
        uint256 ethBob = uint256(e.ethOut) * b / (uint256(a) + b);
        uint256 stopAlice = uint256(e.unsold) * a / (uint256(a) + b);
        uint256 stopBob = uint256(e.unsold) * b / (uint256(a) + b);
        vm.prank(reverse ? bob : alice);
        (uint256 eth1, uint256 stop1) = hook.claim(reverse ? second : first);
        vm.prank(reverse ? alice : bob);
        (uint256 eth2, uint256 stop2) = hook.claim(reverse ? first : second);
        assertEq(eth1, reverse ? ethBob : ethAlice);
        assertEq(eth2, reverse ? ethAlice : ethBob);
        assertEq(stop1, reverse ? stopBob : stopAlice);
        assertEq(stop2, reverse ? stopAlice : stopBob);
        assertEq(manager.balanceOf(address(hook), 0), uint256(e.ethOut) - ethAlice - ethBob);
        assertEq(token.balanceOf(address(hook)), uint256(e.unsold) - stopAlice - stopBob);
        assertLe(token.balanceOf(address(hook)), 1);
        assertLe(manager.balanceOf(address(hook), 0), 1);
    }

    function test_negativeTicksAndBitmapWordBoundary() public {
        _toTick(-120);
        _place(alice, -60, 1 ether);
        _place(alice, 0, 1 ether);
        _place(bob, 60, 1 ether);
        _toTick(60);
        assertTrue(hook.epoch(poolId, -60, 0).executed);
        assertTrue(hook.epoch(poolId, 0, 0).executed);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.activeTicks(poolId, -1), 0);
        assertEq(hook.activeTicks(poolId, 0), 0);
    }

    function test_cancelledOrderExcludedFromExecutedDenominator() public {
        uint256 a = _place(alice, 60, 10 ether);
        uint256 b = _place(bob, 60, 20 ether);
        vm.prank(alice);
        hook.cancel(a);
        _toTick(60);
        StopLossHook.Epoch memory e = hook.epoch(poolId, 60, 0);
        assertEq(e.amount, 20 ether);
        vm.prank(bob);
        (uint256 eth,) = hook.claim(b);
        assertEq(eth, e.ethOut);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        vm.expectRevert(StopLossHook.InvalidOrder.selector);
        vm.prank(alice);
        hook.claim(a);
    }

    function test_farCrossingSkipsStaleWordsAndExecutesEligibleTail() public {
        // More than four bitmap words crossed, but only the live limit window is relevant.
        _place(alice, 60, 1 ether);
        _place(alice, 76800, 1 ether);
        _toTick(76800);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        StopLossHook.Epoch memory e = hook.epoch(poolId, 76800, 0);
        assertTrue(e.executed);
        assertEq(e.unsold, 1 ether); // Beyond the seeded range: no liquidity, no loss.
        assertEq(e.ethOut, 0);
    }

    function test_poolIsolationAndNoLiquidityRefund() public {
        uint256 a = _place(alice, 60, 1 ether);
        MockERC20 other = new MockERC20("Other", "OTHER", 1e27);
        PoolKey memory second = key;
        second.currency1 = Currency.wrap(address(other));
        manager.initialize(second, TickMath.getSqrtPriceAtTick(0));
        other.approve(address(hook), 2 ether);
        uint256 b = hook.placeOrder(second, 60, 2 ether);
        driver.swap(second, SwapParams(false, -int256(1 ether), TickMath.getSqrtPriceAtTick(60)));
        assertTrue(hook.epoch(second.toId(), 60, 0).executed);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.openAmount(poolId, 60), 1 ether);
        (uint256 eth, uint256 stop) = hook.claim(b);
        assertEq(eth, 0);
        assertEq(stop, 2 ether);
        assertEq(other.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 1 ether);
        vm.prank(alice);
        hook.cancel(a);
    }

    function test_orderPlacedIndexesOwnerAndPool() public {
        vm.recordLogs();
        uint256 id = _place(alice, 60, 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory placed = logs[logs.length - 1];
        assertEq(placed.emitter, address(hook));
        assertEq(placed.topics[0], keccak256("OrderPlaced(uint256,address,bytes32,int24,uint128,uint256)"));
        assertEq(placed.topics[1], bytes32(id));
        assertEq(placed.topics[2], bytes32(uint256(uint160(alice))));
        assertEq(placed.topics[3], PoolId.unwrap(poolId));
        assertEq(placed.data, abi.encode(int24(60), uint128(1 ether), uint256(0)));
    }

    function test_exactOutputSellAndBuy() public {
        _place(alice, 60, 1 ether);
        BalanceDelta sold = driver.swap(key, SwapParams(false, 1e22, TickMath.getSqrtPriceAtTick(420)));
        assertGt(sold.amount0(), 0);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
        _place(bob, 600, 1 ether);
        BalanceDelta bought = driver.swap(key, SwapParams(true, 1e22, TickMath.getSqrtPriceAtTick(-420)));
        assertGt(bought.amount1(), 0);
        assertFalse(hook.epoch(poolId, 600, 0).executed);
    }
}

contract LaunchRehearsalTest is HookFixture {
    function setUp() public {
        _deploy();
    }

    function test_launchOneSidedStopFirstBuyThenSell() public {
        _seed(0, -12000, 0, LIQUIDITY);
        assertEq(address(manager).balance, 0, "seed has no ETH");
        assertGt(token.balanceOf(address(manager)), 0);
        BalanceDelta buy = _toTick(-600);
        assertLt(buy.amount0(), 0);
        assertGt(buy.amount1(), 0);
        assertGt(address(manager).balance, 0);
        uint256 id = _place(alice, -540, 10 ether);
        BalanceDelta sell = _toTick(-480);
        assertGt(sell.amount0(), 0);
        assertLt(sell.amount1(), 0);
        assertTrue(hook.epoch(poolId, -540, 0).executed);
        assertGt(manager.balanceOf(address(hook), 0), 0);
        vm.prank(alice);
        hook.claim(id);
        assertGt(alice.balance, 0);
    }
}
