# ABI integration

These JSON files are raw compiler ABI arrays, regenerated with `forge inspect ... abi --json`.
`STOP.json` includes the ERC-20 metadata, balances, allowances, transfer/approval calls and errors.
It has no constructor parameters and no externally callable mint function.

`StopLossHook.json` is the complete ABI, including inherited v4 callbacks. Only `beforeSwap`
and `afterSwap` are enabled; all callbacks authenticate the PoolManager. Applications use:

| Call | Result / semantics |
| --- | --- |
| `placeOrder(PoolKey,int24,uint128)` | Approve currency1 first; returns globally increasing order ID starting at 1 |
| `cancel(uint256)` | Owner-only refund before epoch execution |
| `claim(uint256)` | Owner-only once after execution; returns ETH and STOP paid |
| `execute(PoolKey,uint256)` | Permissionless; maximum 1–5; returns number of epochs executed |
| `order(uint256)` | Owner, pool ID, trigger tick, amount, epoch ID, cancelled, claimed |
| `epoch(bytes32,int24,uint256)` | Amount, ETH output, unsold STOP, executed, claimed ETH, claimed STOP |
| `openEpoch(bytes32,int24)` | Current open epoch ID, starting at 0 |
| `openAmount(bytes32,int24)` | Aggregate STOP in that trigger's current open epoch |
| `activeTicks(bytes32,int16)` | Word of active trigger bits; ticks compressed by 60 |
| `getHookPermissions()` | Exactly beforeSwap and afterSwap |
| `poolManager()` | Immutable manager address |

`PoolKey` is the tuple `(address currency0, address currency1, uint24 fee, int24 tickSpacing,
address hooks)`. Pool IDs use v4's `keccak256(abi.encode(key))`. Epoch IDs are scoped to pool
and trigger; order IDs are global. Nonexistent order/epoch views return zero-filled structs;
check `order.owner != address(0)` for existence. A completely cancelled epoch can be reused
until it executes; execution alone advances the epoch ID.

`OrderPlaced` indexes order ID, owner and pool ID, with tick, amount and epoch in its data.
`OrderCancelled` indexes order ID. `BucketExecuted` indexes pool, trigger and epoch, and
includes actual STOP sold, ETH credited and STOP remaining. `Claimed` indexes order ID and
owner, with the two amounts actually paid. All amounts are base units and all ticks signed.

The constructor of `StopLossHook` takes only the manager address. No token address or admin
is a constructor parameter. Clients discover the reviewed STOP address and pool key from
the service-produced deployment result. Do not call `unlockCallback` directly or use the
test-only PoolDriver as a production router.
