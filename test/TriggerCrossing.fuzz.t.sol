// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {StopLossHook} from "../src/StopLossHook.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @dev Model deposits/refunds independently; derive fills from real PoolManager Swap events,
/// not the hook's epoch totals. Every action reconciles custody, claims, bitmap and settlement.
contract TriggerCrossingFuzzTest is HookFixture {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    bytes32 constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    struct Bucket {
        int24 trigger;
        uint256 amount;
        uint256 eth;
        uint256 unsold;
        uint256 paidEth;
        uint256 paidStop;
        bool executed;
    }

    struct Deposit {
        uint256 id;
        address owner;
        uint128 amount;
        uint8 bucket;
        bool cancelled;
        bool claimed;
    }

    struct Balances {
        uint256 poolStop;
        uint256 poolEth;
        uint256 routerStop;
        uint256 routerEth;
        uint256 claims;
    }

    Bucket[8] internal buckets;
    Deposit[] internal deposits;

    function setUp() public {
        _deploy();
        _seed(0, -12000, 12000, LIQUIDITY);
    }

    function testFuzz_zeroToEightCrossingsWithCancelsClaimsAndCatchUp(
        uint256 seed,
        uint8 crossingSeed,
        uint16 cancelMask,
        uint16 claimMask,
        bool partialFills,
        bool negativeTicks
    ) public {
        _scenario(seed, uint8(bound(crossingSeed, 0, 8)), cancelMask, claimMask, partialFills, negativeTicks);
    }

    // Guarantee every crossing count, including the five-bucket cap, independent of fuzz distribution.
    function test_allNineCrossingCountsFullAndPartialFills() public {
        uint256 snapshot = vm.snapshotState();
        for (uint8 count; count <= 8; ++count) {
            this.fixedScenario(count, false);
            assertTrue(vm.revertToState(snapshot));
            this.fixedScenario(count, true);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    // A separate call frame releases each scenario's memory during exhaustive enumeration.
    function fixedScenario(uint8 count, bool partialFills) external {
        require(msg.sender == address(this));
        _scenario(partialFills ? 456 : 123, count, 0, 0x5555, partialFills, partialFills);
    }

    function _scenario(
        uint256 seed,
        uint8 count,
        uint16 cancelMask,
        uint16 claimMask,
        bool partialFills,
        bool negativeTicks
    ) internal {
        int24 base = negativeTicks ? int24(-240) : int24(0);
        if (negativeTicks) _toTick(base);
        _populate(seed, base, partialFills);
        for (uint256 i; i < deposits.length; ++i) {
            if ((uint256(cancelMask) >> i) & 1 != 0) _cancel(i);
        }

        // At zero crossings the user still sells, ending strictly below the first trigger.
        int24 target = base + (count == 0 ? int24(30) : int24(uint24(count)) * 60);
        _swapTo(target, seed & 2 != 0);
        uint256 expectedCount;
        for (uint256 i; i < 8; ++i) {
            bool expected = i < count && buckets[i].amount != 0 && expectedCount < 5;
            assertEq(buckets[i].executed, expected, "automatic crossing/cap model");
            if (expected) ++expectedCount;
        }

        // Claim/cancel in a rotated order; other entitlements must survive each transfer.
        for (uint256 step; step < deposits.length; ++step) {
            uint256 i = (step + seed % deposits.length) % deposits.length;
            if (deposits[i].cancelled) continue;
            _refuse(i, address(0xBAD), false, StopLossHook.NotOwner.selector);
            _refuse(i, address(0xBAD), true, StopLossHook.NotOwner.selector);
            if (buckets[deposits[i].bucket].executed) {
                _refuse(i, deposits[i].owner, false, StopLossHook.AlreadyExecuted.selector);
                if ((uint256(claimMask) >> i) & 1 != 0) _claim(i);
            } else {
                _refuse(i, deposits[i].owner, true, StopLossHook.NotExecuted.selector);
                if ((uint256(claimMask) >> i) & 1 != 0) _cancel(i);
            }
        }

        // A one-tick buy can leave crossed buckets eligible. It must not fill that backlog.
        _swapTo(_tick() - 1, seed & 1 != 0);
        _invalidExecute(0);
        _invalidExecute(6 + seed % 100);
        // Max=1..5, permissionless caller, repeated snapshots: own-swap crossings catch up later.
        for (uint256 i; i < 8; ++i) {
            _execute(1 + uint256(keccak256(abi.encode(seed, i))) % 5);
        }

        for (uint256 step; step < deposits.length; ++step) {
            uint256 i = deposits.length - 1 - step;
            if (deposits[i].claimed || deposits[i].cancelled) continue;
            if (buckets[deposits[i].bucket].executed) _claim(i);
            else _cancel(i);
        }
        _execute(5);
        // Only documented per-share flooring dust can remain after all owners exit.
        assertLt(token.balanceOf(address(hook)), deposits.length);
        assertLt(manager.balanceOf(address(hook), 0), deposits.length);
    }

    function testFuzz_buysAcrossAllPendingTriggersNeverExecute(uint256 seed, bool exactOutput) public {
        _populate(seed, 0, true);
        // Gap past ALL limits: the sell succeeds but all eight buckets remain open.
        _swapTo(1800, false);
        for (uint256 i; i < 8; ++i) {
            assertFalse(buckets[i].executed);
        }
        // Return inside every execution window without crossing a trigger yet.
        _swapTo(900, exactOutput);
        for (uint256 i; i < 8; ++i) {
            assertFalse(buckets[i].executed);
        }
        // Now cross all eight trigger ticks in the buy direction, with pending STOP in custody.
        _swapTo(0, exactOutput);
        for (uint256 i; i < 8; ++i) {
            assertFalse(buckets[i].executed);
        }
        for (uint256 i; i < deposits.length; ++i) {
            _cancel(i);
        }
    }

    function testFuzz_cancelEveryOrderThenReuseBitmap(uint256 seed) public {
        _populate(seed, 0, false);
        for (uint256 i; i < deposits.length; ++i) {
            _cancel(i);
        }
        assertEq(hook.activeTicks(poolId, 0), 0);
        delete deposits;
        delete buckets;
        _populate(seed ^ 1, 0, true);
        _swapTo(480, false);
        _execute(5);
        for (uint256 i; i < deposits.length; ++i) {
            _claim(i);
        }
    }

    function _populate(uint256 seed, int24 base, bool partialFills) internal {
        for (uint8 i; i < 8; ++i) {
            buckets[i].trigger = base + int24(uint24(i + 1)) * 60;
            for (uint256 j; j < 2; ++j) {
                uint256 random = uint256(keccak256(abi.encode(seed, i, j)));
                uint128 amount =
                    uint128(bound(random, partialFills ? 1e24 : 1 ether, partialFills ? 2e24 : 1e19));
                address owner = j == 0 ? alice : bob;
                uint256 id = _place(owner, buckets[i].trigger, amount);
                buckets[i].amount += amount;
                deposits.push(Deposit(id, owner, amount, i, false, false));
                _assertState();
            }
        }
    }

    function _expected(int24 lower, int24 upper, uint160 price, uint256 maximum)
        internal
        view
        returns (bool[8] memory expected, uint256 count)
    {
        for (uint256 i; i < 8 && count < maximum; ++i) {
            Bucket storage b = buckets[i];
            if (
                !b.executed && b.amount != 0 && b.trigger > lower && b.trigger <= upper
                    && price < TickMath.getSqrtPriceAtTick(b.trigger + 1200)
            ) {
                expected[i] = true;
                ++count;
            }
        }
    }

    function _balances() internal view returns (Balances memory b) {
        return Balances(
            token.balanceOf(address(manager)),
            address(manager).balance,
            token.balanceOf(address(driver)),
            address(driver).balance,
            manager.balanceOf(address(hook), 0)
        );
    }

    function _swapTo(int24 target, bool exactOutput) internal {
        (uint160 price, int24 beforeTick,,) = manager.getSlot0(poolId);
        uint160 limit = TickMath.getSqrtPriceAtTick(target);
        bool buy = limit < price;
        bool[8] memory expected;
        if (!buy) (expected,) = _expected(beforeTick, target, limit, 5);
        Balances memory before = _balances();
        vm.recordLogs();
        BalanceDelta delta =
            driver.swap(key, SwapParams(buy, exactOutput ? int256(1e26) : -int256(1e26), limit));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertUserSwap(logs, delta, limit);
        (uint256 sold, uint256 eth) = _recordFills(logs, expected);
        assertEq(
            int256(token.balanceOf(address(manager))) - int256(before.poolStop),
            -int256(delta.amount1()) + int256(sold),
            "pool STOP cashflow"
        );
        // Hook ETH stays in the manager as ERC-6909 collateral until claim().
        assertEq(
            int256(address(manager).balance) - int256(before.poolEth),
            -int256(delta.amount0()),
            "pool ETH cashflow"
        );
        assertEq(
            int256(token.balanceOf(address(driver))) - int256(before.routerStop),
            int256(delta.amount1()),
            "seller/buyer STOP"
        );
        assertEq(
            int256(address(driver).balance) - int256(before.routerEth),
            int256(delta.amount0()),
            "seller/buyer ETH"
        );
        assertEq(manager.balanceOf(address(hook), 0) - before.claims, eth, "new ETH claims");
        if (buy) {
            assertEq(sold, 0, "buy executed STOP");
            assertEq(eth, 0, "buy generated order proceeds");
        }
        _assertState();
    }

    function _assertUserSwap(Vm.Log[] memory logs, BalanceDelta delta, uint160 limit) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(manager) || entry.topics[0] != SWAP
                    || entry.topics[2] != bytes32(uint256(uint160(address(driver))))
            ) continue;
            (int128 eth, int128 stop, uint160 price,,,) =
                abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            // This is the user's endpoint BEFORE hook sells: proves how many levels were crossed.
            assertEq(price, limit, "outer swap reached requested crossing count");
            assertEq(eth, delta.amount0());
            assertEq(stop, delta.amount1());
            ++count;
        }
        assertEq(count, 1, "one user swap");
    }

    function _execute(uint256 maximum) internal {
        (uint160 price, int24 tick,,) = manager.getSlot0(poolId);
        (bool[8] memory expected, uint256 count) = _expected(TickMath.MIN_TICK, tick, price, maximum);
        Balances memory before = _balances();
        vm.recordLogs();
        vm.prank(address(0xCA11));
        assertEq(hook.execute(key, maximum), count, "keeper count");
        (uint256 sold, uint256 eth) = _recordFills(vm.getRecordedLogs(), expected);
        assertEq(token.balanceOf(address(manager)) - before.poolStop, sold, "keeper STOP settlement");
        assertEq(address(manager).balance, before.poolEth, "keeper ETH remains collateral");
        assertEq(manager.balanceOf(address(hook), 0) - before.claims, eth, "keeper claims");
        _assertState();
    }

    function _recordFills(Vm.Log[] memory logs, bool[8] memory expected)
        internal
        returns (uint256 soldTotal, uint256 ethTotal)
    {
        uint256 cursor;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (
                entry.emitter != address(manager) || entry.topics[0] != SWAP
                    || entry.topics[2] != bytes32(uint256(uint160(address(hook))))
            ) continue;
            while (cursor < 8 && !expected[cursor]) ++cursor;
            assertLt(cursor, 8, "unexpected internal swap (including on buy)");
            assertEq(entry.topics[1], PoolId.unwrap(poolId));
            (int128 eth, int128 stop, uint160 price,,,) =
                abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            assertGe(eth, 0);
            assertLe(stop, 0);
            Bucket storage b = buckets[cursor];
            uint256 sold = uint256(-int256(stop));
            assertLe(sold, b.amount);
            assertLe(price, TickMath.getSqrtPriceAtTick(b.trigger + 1200), "bucket price limit");
            b.eth = uint256(int256(eth));
            b.unsold = b.amount - sold;
            b.executed = true;
            soldTotal += sold;
            ethTotal += b.eth;
            ++cursor;
        }
        for (; cursor < 8; ++cursor) {
            assertFalse(expected[cursor], "missing internal swap");
        }
    }

    function _cancel(uint256 i) internal {
        Deposit storage d = deposits[i];
        uint256 balance = token.balanceOf(d.owner);
        vm.prank(d.owner);
        hook.cancel(d.id);
        d.cancelled = true;
        buckets[d.bucket].amount -= d.amount;
        assertEq(token.balanceOf(d.owner) - balance, d.amount, "exact cancellation refund");
        _assertState();
        _refuse(i, d.owner, false, StopLossHook.InvalidOrder.selector);
        _refuse(i, d.owner, true, StopLossHook.InvalidOrder.selector);
    }

    function _claim(uint256 i) internal {
        Deposit storage d = deposits[i];
        Bucket storage b = buckets[d.bucket];
        uint256 expectedEth = b.eth * d.amount / b.amount;
        uint256 expectedStop = b.unsold * d.amount / b.amount;
        uint256 ownerEth = d.owner.balance;
        uint256 ownerStop = token.balanceOf(d.owner);
        uint256 poolEth = address(manager).balance;
        uint256 claims = manager.balanceOf(address(hook), 0);
        vm.prank(d.owner);
        (uint256 eth, uint256 stop) = hook.claim(d.id);
        d.claimed = true;
        b.paidEth += expectedEth;
        b.paidStop += expectedStop;
        assertEq(eth, expectedEth);
        assertEq(stop, expectedStop);
        assertEq(d.owner.balance - ownerEth, expectedEth);
        assertEq(token.balanceOf(d.owner) - ownerStop, expectedStop);
        assertEq(poolEth - address(manager).balance, expectedEth);
        assertEq(claims - manager.balanceOf(address(hook), 0), expectedEth);
        _assertState();
        _refuse(i, d.owner, true, StopLossHook.InvalidOrder.selector);
        _refuse(i, d.owner, false, StopLossHook.InvalidOrder.selector);
    }

    function _refuse(uint256 i, address caller, bool claiming, bytes4 reason) internal {
        uint256 stop = token.balanceOf(caller);
        uint256 eth = caller.balance;
        vm.expectRevert(reason);
        vm.prank(caller);
        if (claiming) hook.claim(deposits[i].id);
        else hook.cancel(deposits[i].id);
        assertEq(token.balanceOf(caller), stop);
        assertEq(caller.balance, eth);
        _assertState();
    }

    function _invalidExecute(uint256 maximum) internal {
        vm.expectRevert(StopLossHook.InvalidBucketCount.selector);
        hook.execute(key, maximum);
        _assertState();
    }

    function _assertState() internal view {
        uint256 stopLiability;
        uint256 ethLiability;
        for (uint256 i; i < 8; ++i) {
            if (i * 2 >= deposits.length) break;
            Bucket storage b = buckets[i];
            StopLossHook.Epoch memory e = hook.epoch(poolId, b.trigger, 0);
            assertEq(e.amount, b.amount, "epoch deposits less cancellations");
            assertEq(e.executed, b.executed, "executed epoch");
            assertEq(e.ethOut, b.eth, "epoch ETH from pool swap");
            assertEq(e.unsold, b.unsold, "epoch unsold from pool swap");
            assertEq(e.claimedEth, b.paidEth, "claimed ETH ledger");
            assertEq(e.claimedStop, b.paidStop, "claimed STOP ledger");
            assertEq(hook.openEpoch(poolId, b.trigger), b.executed ? 1 : 0);
            assertEq(hook.openAmount(poolId, b.trigger), b.executed ? 0 : b.amount);
            (int16 word, uint8 bit) = TickBitmap.position(b.trigger / 60);
            assertEq(hook.activeTicks(poolId, word) & (uint256(1) << bit) != 0, !b.executed && b.amount != 0);
            stopLiability += b.executed ? b.unsold - b.paidStop : b.amount;
            ethLiability += b.eth - b.paidEth;
        }
        for (uint256 i; i < deposits.length; ++i) {
            Deposit storage d = deposits[i];
            StopLossHook.Order memory o = hook.order(d.id);
            assertEq(o.owner, d.owner);
            assertEq(o.amount, d.amount);
            assertEq(o.triggerTick, buckets[d.bucket].trigger);
            assertEq(PoolId.unwrap(o.poolId), PoolId.unwrap(poolId));
            assertEq(o.epoch, 0);
            assertEq(o.cancelled, d.cancelled);
            assertEq(o.claimed, d.claimed);
        }
        // Residual epoch amounts include the explicitly documented rounding dust.
        assertEq(token.balanceOf(address(hook)), stopLiability, "STOP = open + unclaimed unsold");
        assertEq(manager.balanceOf(address(hook), 0), ethLiability, "ETH claims = unclaimed epoch ETH");
        assertEq(address(hook).balance, 0);
        assertEq(manager.currencyDelta(address(hook), key.currency0), 0);
        assertEq(manager.currencyDelta(address(hook), key.currency1), 0);
        assertEq(manager.currencyDelta(address(driver), key.currency0), 0);
        assertEq(manager.currencyDelta(address(driver), key.currency1), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
    }
}
