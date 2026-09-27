// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permissionless stop-loss buckets for native ETH / standard 18-decimal token pools.
/// @dev Higher ticks mean a lower ETH price for currency1. No admin, fees, or return deltas.
contract StopLossHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using SafeERC20 for IERC20;

    int24 public constant TICK_SPACING = 60;
    int24 public constant LIMIT_OFFSET = 1200;
    uint256 public constant MIN_ORDER = 1 ether;
    uint256 public constant MAX_BUCKETS = 5;
    uint256 public constant MAX_WORDS = 4;

    struct Order {
        address owner;
        PoolId poolId;
        int24 triggerTick;
        uint128 amount;
        uint256 epoch;
        bool cancelled;
        bool claimed;
    }

    struct Epoch {
        uint128 amount;
        uint128 ethOut;
        uint128 unsold;
        bool executed;
        uint128 claimedEth;
        uint128 claimedStop;
    }

    mapping(uint256 => Order) private _orders;
    mapping(PoolId => mapping(int24 => mapping(uint256 => Epoch))) private _epochs;
    mapping(PoolId => mapping(int24 => uint256)) public openEpoch;
    mapping(PoolId => mapping(int16 => uint256)) public activeTicks;
    mapping(PoolId => PoolKey) private _keys;
    uint256 public nextOrderId = 1;
    bytes32 private _expectedUnlock;

    error InvalidPool();
    error InvalidOrder();
    error InvalidTrigger();
    error InvalidAmount();
    error NotOwner();
    error AlreadyExecuted();
    error NotExecuted();
    error InvalidBucketCount();
    error UnexpectedUnlock();
    error UnsupportedToken();
    error InvalidDelta();

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        PoolId indexed poolId,
        int24 triggerTick,
        uint128 amount,
        uint256 epoch
    );
    event OrderCancelled(uint256 indexed orderId);
    event BucketExecuted(
        PoolId indexed poolId,
        int24 indexed triggerTick,
        uint256 indexed epoch,
        uint256 stopSold,
        uint256 ethOut,
        uint256 unsold
    );
    event Claimed(uint256 indexed orderId, address indexed owner, uint256 eth, uint256 stop);

    constructor(IPoolManager manager) BaseHook(manager) {
        if (address(manager) == address(0)) revert InvalidPool();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function order(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function epoch(PoolId poolId, int24 triggerTick, uint256 epochId) external view returns (Epoch memory) {
        return _epochs[poolId][triggerTick][epochId];
    }

    function openAmount(PoolId poolId, int24 triggerTick) external view returns (uint128) {
        return _epochs[poolId][triggerTick][openEpoch[poolId][triggerTick]].amount;
    }

    function placeOrder(PoolKey calldata key, int24 triggerTick, uint128 amount)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        _validatePool(key);
        PoolId id = key.toId();
        (uint160 price, int24 tick,,) = poolManager.getSlot0(id);
        if (price == 0) revert InvalidPool();
        if (
            triggerTick % TICK_SPACING != 0 || triggerTick <= tick || triggerTick < TickMath.MIN_TICK
                || triggerTick > TickMath.MAX_TICK - LIMIT_OFFSET
        ) revert InvalidTrigger();
        uint256 epochId = openEpoch[id][triggerTick];
        Epoch storage e = _epochs[id][triggerTick][epochId];
        if (amount < MIN_ORDER || uint256(e.amount) + amount > uint128(type(int128).max)) {
            revert InvalidAmount();
        }
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - beforeBalance != amount) revert UnsupportedToken();
        if (e.amount == 0) activeTicks[id].flipTick(triggerTick, TICK_SPACING);
        e.amount += amount;
        _keys[id] = key;
        orderId = nextOrderId++;
        _orders[orderId] = Order(msg.sender, id, triggerTick, amount, epochId, false, false);
        emit OrderPlaced(orderId, msg.sender, id, triggerTick, amount, epochId);
    }

    function cancel(uint256 orderId) external nonReentrant {
        Order storage o = _ownedOrder(orderId);
        Epoch storage e = _epochs[o.poolId][o.triggerTick][o.epoch];
        if (e.executed) revert AlreadyExecuted();
        o.cancelled = true;
        e.amount -= o.amount;
        if (e.amount == 0) activeTicks[o.poolId].flipTick(o.triggerTick, TICK_SPACING);
        IERC20(Currency.unwrap(_keys[o.poolId].currency1)).safeTransfer(o.owner, o.amount);
        emit OrderCancelled(orderId);
    }

    function claim(uint256 orderId) external nonReentrant returns (uint256 eth, uint256 stop) {
        Order storage o = _ownedOrder(orderId);
        Epoch storage e = _epochs[o.poolId][o.triggerTick][o.epoch];
        if (!e.executed) revert NotExecuted();
        o.claimed = true;
        eth = uint256(e.ethOut) * o.amount / e.amount;
        stop = uint256(e.unsold) * o.amount / e.amount;
        // Each pro-rata share is bounded by its uint128 epoch total.
        // forge-lint: disable-next-line(unsafe-typecast)
        e.claimedEth += uint128(eth);
        // forge-lint: disable-next-line(unsafe-typecast)
        e.claimedStop += uint128(stop);
        if (stop != 0) IERC20(Currency.unwrap(_keys[o.poolId].currency1)).safeTransfer(o.owner, stop);
        if (eth != 0) _unlock(abi.encode(true, abi.encode(o.owner, eth)));
        emit Claimed(orderId, o.owner, eth, stop);
    }

    /// @notice Catch up eligible buckets. Repeated calls may be needed after hook-induced crossings.
    function execute(PoolKey calldata key, uint256 maxBuckets) external nonReentrant returns (uint256) {
        _validatePool(key);
        if (maxBuckets == 0 || maxBuckets > MAX_BUCKETS) revert InvalidBucketCount();
        return abi.decode(_unlock(abi.encode(false, abi.encode(key, maxBuckets))), (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (_expectedUnlock == bytes32(0) || _expectedUnlock != keccak256(data)) revert UnexpectedUnlock();
        delete _expectedUnlock;
        (bool isClaim, bytes memory payload) = abi.decode(data, (bool, bytes));
        if (isClaim) {
            (address owner, uint256 eth) = abi.decode(payload, (address, uint256));
            poolManager.burn(address(this), 0, eth);
            poolManager.take(Currency.wrap(address(0)), owner, eth);
            return "";
        }
        (PoolKey memory key, uint256 maxBuckets) = abi.decode(payload, (PoolKey, uint256));
        (uint160 price, int24 tick,,) = poolManager.getSlot0(key.toId());
        if (price == 0) revert InvalidPool();
        return abi.encode(_scan(key, tick - LIMIT_OFFSET, tick, maxBuckets));
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());
        bytes32 slot = _tickSlot(key.toId());
        assembly ("memory-safe") {
            tstore(slot, tick)
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        bytes32 slot = _tickSlot(key.toId());
        int24 beforeTick;
        assembly ("memory-safe") {
            beforeTick := tload(slot)
            tstore(slot, 0)
        }
        if (!params.zeroForOne) {
            (, int24 afterTick,,) = poolManager.getSlot0(key.toId());
            // This snapshot deliberately excludes levels crossed by our own subsequent swaps.
            int24 lower = afterTick - LIMIT_OFFSET;
            if (beforeTick > lower) lower = beforeTick;
            _scan(key, lower, afterTick, MAX_BUCKETS);
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _scan(PoolKey memory key, int24 cursor, int24 upper, uint256 maxBuckets)
        private
        returns (uint256 filled)
    {
        PoolId id = key.toId();
        uint256 words;
        int16 lastWord = type(int16).min;
        // The live 1200-tick window contains at most 20 trigger levels and two bitmap words.
        while (cursor < upper && filled < maxBuckets) {
            (int16 word,) = TickBitmap.position(TickBitmap.compress(cursor, TICK_SPACING) + 1);
            if (word != lastWord) {
                if (++words > MAX_WORDS) break;
                lastWord = word;
            }
            (int24 next, bool initialized) =
                activeTicks[id].nextInitializedTickWithinOneWord(cursor, TICK_SPACING, false);
            if (next > upper) break;
            cursor = next;
            if (initialized && _fill(key, id, next)) ++filled;
        }
    }

    function _fill(PoolKey memory key, PoolId id, int24 trigger) private returns (bool) {
        (uint160 price,,,) = poolManager.getSlot0(id);
        uint160 limit = TickMath.getSqrtPriceAtTick(trigger + LIMIT_OFFSET);
        // At a downward initialized-tick crossing, tick can be limitTick - 1 while price == limit.
        if (price >= limit) return false;
        uint256 epochId = openEpoch[id][trigger];
        Epoch storage e = _epochs[id][trigger][epochId];
        e.executed = true;
        activeTicks[id].flipTick(trigger, TICK_SPACING);
        openEpoch[id][trigger] = epochId + 1;
        BalanceDelta delta = poolManager.swap(key, SwapParams(false, -int256(uint256(e.amount)), limit), "");
        if (delta.amount0() < 0 || delta.amount1() > 0) revert InvalidDelta();
        uint256 sold = uint256(-int256(delta.amount1()));
        uint128 eth = uint128(delta.amount0());
        if (sold > e.amount) revert InvalidDelta();
        e.ethOut = eth;
        // sold <= the uint128 epoch amount was checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        e.unsold = e.amount - uint128(sold);
        if (sold != 0) {
            poolManager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), sold);
            if (poolManager.settle() != sold) revert UnsupportedToken();
        }
        if (eth != 0) poolManager.mint(address(this), 0, eth);
        emit BucketExecuted(id, trigger, epochId, sold, eth, e.unsold);
        return true;
    }

    function _unlock(bytes memory data) private returns (bytes memory result) {
        _expectedUnlock = keccak256(data);
        result = poolManager.unlock(data);
        if (_expectedUnlock != bytes32(0)) revert UnexpectedUnlock();
    }

    function _ownedOrder(uint256 orderId) private view returns (Order storage o) {
        o = _orders[orderId];
        if (o.owner == address(0) || o.cancelled || o.claimed) revert InvalidOrder();
        if (o.owner != msg.sender) revert NotOwner();
    }

    function _validatePool(PoolKey memory key) private view {
        if (
            address(key.hooks) != address(this) || !key.currency0.isAddressZero()
                || key.currency1.isAddressZero() || key.tickSpacing != TICK_SPACING || key.fee != 3000
        ) revert InvalidPool();
    }

    function _tickSlot(PoolId id) private pure returns (bytes32) {
        return keccak256(abi.encode("StopLossHook.beforeTick", id));
    }
}
