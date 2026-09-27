// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract FiveBucketGasTest is HookFixture {
    function setUp() public {
        _deploy();
        _seed(0, -12000, 12000, LIQUIDITY);
        for (int24 i = 1; i <= 7; ++i) {
            _place(alice, i * 60, 1 ether);
        }
    }

    function test_gasSellExecutingFiveBuckets() public {
        vm.cool(address(hook));
        vm.cool(address(manager));
        vm.cool(address(driver));
        vm.cool(address(token));
        SwapParams memory params = SwapParams(false, -int256(1e26), TickMath.getSqrtPriceAtTick(420));
        uint256 start = gasleft();
        driver.swap(key, params);
        uint256 used = start - gasleft();
        emit log_named_uint("cold router sell, five existing buckets, gross execution gas", used);
        for (int24 i = 1; i <= 7; ++i) {
            assertEq(hook.epoch(poolId, i * 60, 0).executed, i <= 5);
        }
    }
}
