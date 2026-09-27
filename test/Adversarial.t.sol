// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {StopLossHook} from "../src/StopLossHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ClaimRecipient {
    StopLossHook immutable hook;
    PoolKey key;
    uint256 public id;
    bool public reject;
    bool public attacked;

    constructor(StopLossHook hook_, PoolKey memory key_) {
        hook = hook_;
        key = key_;
    }

    function place(uint128 amount) external {
        IERC20(Currency.unwrap(key.currency1)).approve(address(hook), amount);
        id = hook.placeOrder(key, 60, amount);
    }

    function setReject(bool value) external {
        reject = value;
    }

    function claim() external {
        hook.claim(id);
    }

    receive() external payable {
        require(!reject, "recipient refused ETH");
        bytes[4] memory calls = [
            abi.encodeCall(hook.placeOrder, (key, int24(1800), uint128(1 ether))),
            abi.encodeCall(hook.cancel, (id)),
            abi.encodeCall(hook.claim, (id)),
            abi.encodeCall(hook.execute, (key, uint256(5)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory reason) = address(hook).call(calls[i]);
            require(
                !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
                "public entry point reentered"
            );
        }
        attacked = true;
    }
}

contract HostileToken is ERC20 {
    bool public tax;
    bool public failTransfer;
    bool public attempted;
    bytes public attack;
    address public hook;

    constructor() ERC20("Hostile", "HOST") {
        _mint(msg.sender, 1e27);
    }

    function configure(bool tax_, bool fail_, address hook_, bytes memory attack_) external {
        tax = tax_;
        failTransfer = fail_;
        hook = hook_;
        attack = attack_;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!failTransfer, "transfer failed");
            if (attack.length != 0 && msg.sender == hook) {
                (bool ok, bytes memory reason) = hook.call(attack);
                require(
                    !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
                    "token reentered hook"
                );
                attempted = true;
            }
            if (tax) {
                super._update(from, address(0), amount / 100);
                amount -= amount / 100;
            }
        }
        super._update(from, to, amount);
    }
}

contract AdversarialTest is HookFixture {
    function setUp() public {
        _deploy();
        _seed(0, -12000, 12000, LIQUIDITY);
    }

    function test_claimReceiverCannotReenterAnyPublicAction() public {
        ClaimRecipient receiver = new ClaimRecipient(hook, key);
        token.transfer(address(receiver), 1 ether);
        receiver.place(1 ether);
        _toTick(60);
        receiver.claim();
        assertTrue(receiver.attacked());
        assertTrue(hook.order(receiver.id()).claimed);
        assertEq(manager.balanceOf(address(hook), 0), 0);
    }

    function test_rejectingEthRollsBackClaimAndUnsoldRefund() public {
        ClaimRecipient receiver = new ClaimRecipient(hook, key);
        token.transfer(address(receiver), 1e25);
        receiver.place(1e25);
        _toTick(60);
        StopLossHook.Epoch memory e = hook.epoch(poolId, 60, 0);
        assertGt(e.unsold, 0);
        receiver.setReject(true);
        vm.expectRevert();
        receiver.claim();
        assertFalse(hook.order(receiver.id()).claimed);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(address(hook)), e.unsold);
        assertEq(manager.balanceOf(address(hook), 0), e.ethOut);
        assertEq(hook.epoch(poolId, 60, 0).claimedEth, 0);
        receiver.setReject(false);
        receiver.claim();
        assertEq(token.balanceOf(address(receiver)), e.unsold);
        assertEq(address(receiver).balance, e.ethOut);
    }

    function test_feeOnTransferDepositRejectedAtomically() public {
        HostileToken other = _hostilePool();
        other.configure(true, false, address(hook), "");
        uint256 balance = other.balanceOf(address(this));
        vm.expectRevert(StopLossHook.UnsupportedToken.selector);
        hook.placeOrder(key, 60, 1 ether);
        assertEq(other.balanceOf(address(this)), balance);
        assertEq(other.balanceOf(address(hook)), 0);
        assertEq(hook.openAmount(poolId, 60), 0);
    }

    function test_tokenTransferCannotReenterDepositCancelOrExecution() public {
        HostileToken other = _hostilePool();
        other.configure(false, false, address(hook), abi.encodeCall(hook.execute, (key, uint256(1))));
        uint256 id = hook.placeOrder(key, 60, 1 ether);
        assertTrue(other.attempted());
        other.configure(false, false, address(hook), abi.encodeCall(hook.cancel, (id)));
        hook.cancel(id);
        id = hook.placeOrder(key, 60, 1 ether);
        other.configure(false, false, address(hook), abi.encodeCall(hook.claim, (id)));
        _toTick(60);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
    }

    function test_failedSettlementRollsBackSwapAndBucket() public {
        HostileToken other = _hostilePool();
        hook.placeOrder(key, 60, 1 ether);
        other.configure(false, true, address(hook), "");
        vm.expectRevert();
        driver.swap(key, SwapParams(false, -int256(1e26), TickMath.getSqrtPriceAtTick(60)));
        assertEq(_tick(), 0);
        assertFalse(hook.epoch(poolId, 60, 0).executed);
        assertEq(hook.openAmount(poolId, 60), 1 ether);
        assertEq(other.balanceOf(address(hook)), 1 ether);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        other.configure(false, false, address(hook), "");
        _toTick(60);
        assertTrue(hook.epoch(poolId, 60, 0).executed);
    }

    function _hostilePool() internal returns (HostileToken other) {
        other = new HostileToken();
        key.currency1 = Currency.wrap(address(other));
        poolId = key.toId();
        other.transfer(address(driver), 5e26);
        other.approve(address(hook), type(uint256).max);
        _seed(0, -12000, 12000, LIQUIDITY);
    }
}
