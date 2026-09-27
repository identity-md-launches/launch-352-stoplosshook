# Local source review and test evidence

This is the implementer's local review, not an independent security review or launch approval.
Independent review is a separate workflow role and must inspect the accepted source, ABIs,
bytecode and generated manifest. There is no `launch.json` produced by this source contribution.

The source review checked permission/address consistency, callback provenance, transient tick
isolation, pool isolation, external-call boundaries, exact-input delta signs, STOP settlement,
ERC-6909 ETH custody, share arithmetic, bitmap iteration bounds and epoch transitions.
Production hook and token runtime tests reject DELEGATECALL, CALLCODE and SELFDESTRUCT while
skipping PUSH immediates; bytecode metadata hashing is disabled as required.

One concrete issue was reproduced and repaired: v4 may report `tick = boundary - 1` after
a downward crossing while its square-root price equals that boundary. Checking only the tick
could then permit an equal-price-limit swap, reverting catch-up execution. The regression
`test_buyAtInitializedLimitBoundaryDoesNotMakeExecuteRevert` first reproduced
`PriceLimitAlreadyExceeded`; `_fill` now compares actual square-root prices and the test passes.

Coverage maps to the approved behavior:

| Requirement | Evidence |
| --- | --- |
| Fixed supply, transfer exactness, no admin mint | `test/STOP.t.sol` |
| Mined address, two permissions, forged callbacks refused | `test/StopLossHook.t.sol` |
| First buy into an ETH-less one-sided pool, followed by sell | `LaunchRehearsalTest` |
| Seven crossed levels, five fills, keeper catch-up | `test_sellCrossingSevenLevelsExecutesFiveThenCatchUp` |
| Price gap beyond limit stays open/cancellable | `test_gapBeyondLimitDoesNotRevertAndRemainsCancellable` |
| Own-swap levels deferred, stale ticks skipped, negative bitmap words | `test/StopLossHook.t.sol` |
| Partial and zero fills, shares, epoch reuse, cancellations, dust | Deterministic tests and `testFuzz_proRataConservationAndDust` |
| Custody survives liquidity removal | `test_claimRemainsSolventAfterLiquidityIsRemoved` |
| Transfer failures roll back; token and recipient reentrancy rejected | `test/Adversarial.t.sol` |
| Liabilities/custody and active bitmap match after arbitrary sequences | `test/Accounting.invariant.t.sol` |
| Five-bucket gas, seller-paid | `test/Gas.t.sol` |

Invariant handlers target only place, cancel, claim, execute, and price movement, with
`fail_on_revert = true`, 64 runs of depth 32. The accounting oracle sums unique executed epochs
and active orders independently from the hook's execution loop. It includes residual rounding
dust; unsolicited asset donations are outside the equality assertion's assumptions.

The supplied protected floor definitions were read and their checks covered locally without
using environment variables. The service-owned protected harness itself consumes attested
creation code via its environment; this contribution does not claim a protected-harness receipt.
Tests use no RPC, environment variables, FFI, or filesystem cheatcodes.

Final local checks with Solidity 0.8.26 and Foundry 1.7.1:

- `forge build`: passed; a subsequent `forge build --offline --force` also passed from a clean build.
- `forge test`: 37 passed, 0 failed, 0 skipped across six suites.
- `forge test --fuzz-runs 1000`: 37 passed, including 1,000 runs for each fuzz test and
  2,048 handler calls per invariant with zero handler reverts.
- `forge fmt --check`: passed.
- Both exported ABIs match the clean compiler artifacts; every vendored source/license hash
  matches `docs/dependencies.json`.

Runtime sizes are 1,722 bytes for STOP and 13,305 bytes for StopLossHook, below EIP-170's
24,576-byte limit. Build lint warnings are confined to test fixtures and their intentional
casts/transfer calls; contract sources build without those warnings.

Before release, the independent reviewer and services must assess the actual artifact and
manifest, run the specified Sepolia rehearsal using the real addresses, verify one-sided
seed parameters and hook bits, and arrange keeper/UI operations. STOP price and execution
timing remain market-dependent. There is no admin rescue for forgotten orders, donated assets,
or dust, and no guarantee that an out-of-window order will ever become executable again.
