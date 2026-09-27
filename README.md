# Stoploss (STOP)

Implemented contract contribution for `lab-stop-loss-hook`, targeting Sepolia (11155111).
`STOP` mints 1,000,000,000 tokens with 18 decimals to its deployer once. `StopLossHook` holds
stop-loss orders, sells eligible buckets through Uniswap v4, and lets each owner claim their
share of ETH proceeds and unsold STOP. Neither contract has an owner, administrator, upgrade,
additional mint path, or hook fee.

The delivered artifacts are contracts, local tests, vendored dependencies, ABI exports, and
integration documentation. The separate manifest contributor owns `launch.json`; independent
review and services handle publication, artifact linkage, admission, and factory deployment.
The live website follows those services. This contribution does not claim a deployment, live
pool address, fork rehearsal, or independent audit.

## Reproduce

```sh
forge build
forge test
forge fmt --check
forge test --fuzz-runs 1000
forge test --match-test test_gasSellExecutingFiveBuckets -vv
```

`foundry.toml` pins Solidity 0.8.26, Cancun, optimizer runs 200, and `bytecode_hash = "none"`.
FFI is disabled and no filesystem cheatcode permissions are granted. All Solidity dependencies
are ordinary files under `lib/`; there are no submodules, package installs, or network-dependent
tests. The verifier supplies the pinned compiler. Dependency revisions, licenses and file
hashes are recorded in [docs/dependencies.json](docs/dependencies.json).

ABI exports: [STOP](docs/abi/STOP.json), [StopLossHook](docs/abi/StopLossHook.json).
Regenerate after source changes:

```sh
forge inspect src/STOP.sol:STOP abi --json > docs/abi/STOP.json
forge inspect src/StopLossHook.sol:StopLossHook abi --json > docs/abi/StopLossHook.json
```

## Order lifecycle

1. Approve the hook to spend STOP, then call `placeOrder(key, triggerTick, amount)`.
   The pool must exist, use native ETH as currency0, a nonzero currency1, fee 3000, spacing 60,
   and this hook. Amount must be at least `1 ether` (one STOP). Trigger ticks are multiples
   of 60 strictly above the current pool tick, within `[-887220, 886020]`. A bucket cannot
   exceed `type(int128).max` input units, matching v4's delta bounds.
2. Orders at the same pool and trigger join its open epoch. The owner can call `cancel(id)`
   until that epoch executes, including when price has jumped too far to fill it. A cancellation
   refunds the exact deposited amount and removes it from the pro-rata denominator.
3. A sell (`zeroForOne = false`) raising the tick through a trigger can execute its bucket.
   `beforeSwap` saves the tick in transient storage. `afterSwap` snapshots the final user-swap
   tick and considers triggers in `(tickBefore, tickAfter]`, in ascending order, filling at
   most five. A buy never triggers orders. Exact-input and exact-output user swaps both work.
4. Each bucket is sold in one exact-input internal swap (`amountSpecified < 0`), with a
   square-root price limit corresponding to `triggerTick + 1200`. This bounds price movement
   to about 11.3% below the trigger's ETH-per-STOP price, before fees. It is a price limit,
   not a guaranteed execution price or minimum ETH payout.
5. The epoch closes after that swap even if it sells only part, or none, of its STOP. New
   orders at that tick use a new epoch after the market permits placement there again.
   Existing executed orders retain their original epoch entitlement.
6. Only the order owner can call `claim(id)`, once. ETH and unsold STOP are independently
   `floor(epochTotal * orderAmount / epochAmount)`. ETH claims are burned and native ETH is
   taken directly to the owner; unsold STOP is transferred from the hook. If either transfer
   fails, the entire claim rolls back and remains retryable. Contract owners must accept ETH.

Ticks measure STOP per ETH: `STOP/ETH = 1.0001^tick`, so `ETH/STOP = 1.0001^-tick` for these
18-decimal assets. **A rising tick means STOP is getting cheaper.** Amounts in the ABI are
base units, not human-readable token values.

## Catch-up and price gaps

Anyone can call `execute(key, maxBuckets)` with a value from 1 to 5. It unlocks the manager
and processes eligible open triggers at or below the current tick. Each call snapshots its
upper tick; levels crossed only by the hook's internal swaps remain for subsequent calls.
There is no keeper reward or guaranteed execution schedule. Wallet users or a separate keeper
must submit catch-up transactions when automatic execution leaves work behind.

A bucket is skipped if the current square-root price is at or above its limit. This includes
the v4 boundary case where the stored tick is one below an initialized price boundary after
a downward crossing. Skipping leaves the epoch open and cancellable. If price returns to the
interval between its trigger and limit, `execute` can fill it; a returning buy itself never
executes it. Stale buckets never prevent eligible later buckets from being considered.

Active levels are held in a pool-specific bitmap using v4-core's `TickBitmap`. The scan starts
above `max(tickBefore, tickAfter - 1200)` for automatic execution and above `currentTick - 1200`
for catch-up. Older levels cannot satisfy the price limit. This narrows the scan to at most
20 trigger levels in at most two bitmap words, with an explicit four-word ceiling. No loop
walks individual orders or all historical levels, even after a gap spanning many words.

## Custody and assumptions

The manager suppresses callbacks when the hook itself is the swap caller. After each bucket
swap, the hook pays its actual STOP debt via `sync -> transfer -> settle`, then mints the ETH
credit as ERC-6909 claims (currency ID 0). Both hook deltas are zero before `afterSwap` returns.
Using claims avoids pushing ETH during a user's swap. `unlockCallback` requires both the
manager as caller and the exact payload of an unlock initiated by the hook. Public order
actions and execution inside `afterSwap` are guarded against reentrancy.

For each token, ignoring unsolicited transfers:

```text
STOP held = sum(open uncancelled orders)
          + sum(executed epoch.unsold - epoch.claimedStop)
ETH claims held = sum(executed epoch.ethOut - epoch.claimedEth)
```

Executed epoch balances include rounding dust, even after all owners have claimed. Flooring
leaves less than one base unit per order per asset; dust stays permanently in the hook with
no sweep authority. Direct token transfers, forced ETH, and donated ERC-6909 claims are also
unrecoverable surplus and are excluded from liabilities. Thus arbitrary donations change the
equality to `held >= liabilities`; they do not change any entitlement.

Only the supplied standard STOP token is intended for launch. Other compatible pools can
attach the hook and have isolated order state by `PoolId`; initialization and liquidity
callbacks are disabled, so the hook does not restrict the factory's seed. Order entry is
restricted to the native-ETH/fee-3000/spacing-60 shape. There is no token allowlist: using a
different currency1 is the caller's risk. Fee-on-transfer deposits are rejected and exact
settlement is checked; rebasing, callback-dependent, paused, or otherwise adversarial tokens
are unsupported and can make their own pools' execution fail. The UI must bind to the
reviewed STOP pool, not infer safety from use of this hook.

Order ownership comes from the direct caller of `placeOrder`, not a swap router or `hookData`.
`hookData` is unauthenticated and ignored; neither a router address nor supplied user data
earns any credit. There are no external oracles, randomness, delegatecalls, or proxies.
Execution is public and subject to transaction ordering, MEV, pool liquidity, and gas costs.

## Deployment and operation handoff

| Parameter | Required value |
| --- | --- |
| Chain | Sepolia, 11155111; Cancun EVM support |
| Token artifact | `src/STOP.sol:STOP`; no constructor arguments |
| Token recipient | Deployment caller (factory); entire fixed supply |
| Hook artifact | `src/StopLossHook.sol:StopLossHook` |
| Hook constructor | One `IPoolManager` argument: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook address flags | Exactly beforeSwap and afterSwap: low 14 bits `0x00c0` (192) |
| Return-delta flags | All false |
| Pool key | `currency0 = address(0)`, `currency1 = deployed STOP`, fee 3000, tickSpacing 60, deployed hook |
| Seed | One-sided STOP liquidity below the opening price |

Services must mine a CREATE2 salt using the actual deployer and complete hook creation code
including its constructor argument. The constructor validates all address permission bits;
there is no production bypass. Source constants and compiler settings determine bytecode.
Opening price, seed amount/range, exact factory address, salt, token/hook addresses, and final
pool ID are deployment outputs or service parameters, not invented local addresses. Services
must verify these against the separately reviewed manifest and signed artifact linkage.

Local tests deploy a genuine v4-core PoolManager and a mined hook. They rehearse one-sided
liquidity, a first buy with no initial pool ETH, a sell, partial fills, claims, and liquidity
withdrawal. Sepolia service rehearsal must still use the actual manager and production router;
the test router is only test infrastructure and is not a production deployment artifact.

Frontend handoff: filter `OrderPlaced` by indexed owner and pool ID, reconcile cancellation,
execution and claim events with current views, and account for reorganizations. Aggregate
open STOP using `openAmount`; do not include executed epochs. The specified Sepolia services
are PoolSwapTest `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe`, StateView
`0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C`, and V4Quoter
`0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227`. Read prices, refresh quotes and choose explicit
swap price limits; hook execution can move price beyond the initiating user's swap endpoint.
Confirm deployed addresses/code during the service phase before wiring the static website.

## Evidence and review

The cold-state benchmark reports **600,802 gross execution gas** for a router sell executing
five existing buckets, using the pinned compiler and a local full-range liquidity fixture.
This excludes transaction intrinsic gas and is fixture-dependent; the test transaction's
total also includes assertions. **The seller pays automatic bucket execution gas.** A caller
of `execute` pays catch-up gas; owners pay approval, placement, cancellation and claim gas.
Reproduce with the gas command above rather than treating this number as a network estimate.

Tests cover success, authorization failure, double claims, partial and zero fills, failed
settlement, failed ETH delivery, exact-input/output trading, bitmap boundaries, independent
pools, epoch reuse, adversarial callbacks and pro-rata fuzzing. Stateful tests assert custody
and bitmap invariants across placement, price movement, execution, cancellation and claims.
See [docs/review.md](docs/review.md) for the local review and remaining service responsibilities.
