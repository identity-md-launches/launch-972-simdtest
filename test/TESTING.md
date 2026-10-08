# Launch test coverage

Run `forge build` and `forge test`. All dependencies are already vendored; the
suite requires neither a network connection nor an RPC URL. To keep local build
artifacts under the disposable test directory, use `--out test/scratch/out
--cache-path test/scratch/cache` with either command.

The existing token and hook suites cover the fixed supply, 90% pool allocation,
all ten fee-decay blocks, all four swap modes, buy-cap boundaries, partial fills,
empty liquidity, LP collection, and unauthorized callbacks. Their shared setup
is exposed as `HookTestFixture` for the additional suites.

`SIMDTESTHookAdversarial.t.sol` adds:

- A differential oracle using an actual Uniswap v4 pool without a hook, with
  identical currencies, opening price, liquidity, and 1.25% fee. A snapshot
  reuses the fixed token supply rather than minting more tokens. Assertions compare
  executed amounts, final price/tick, exact fee growth, donations, and settlement.
- Randomized over-cap buys across independent block/time windows, checking
  complete rollback and a subsequent successful purchase.
- Fee arithmetic near the signed 128-bit boundary, wrong token decimals,
  unopened callbacks, every pool-key field, zero swaps, and failed ERC-20 settlement.

`SIMDTESTLaunchInvariant.t.sol` targets only the six actions in
`helpers/LaunchHandler.sol`: four-mode swaps, transfers/allowance spending,
independent clock advances, LP additions/removals, collection, and rejected buys.
The handler receives existing tokens once; no action mints tokens, changes storage
directly, or resets the clocks. Unexpected reverts fail the campaign. Assertions
check supply and asset conservation, tracked pool balances, per-swap donations,
zero unsettled deltas/claims, immutable opening times, and position liquidity.
After each sequence, both LP positions must be redeemable with only bounded
integer-rounding dust left in PoolManager.

Both new suites run with either currency ordering. Inline configuration on the
concrete contracts sets 1,000 cases for each fuzz property and 256 sequences of
64 calls for each invariant campaign; concrete annotations also apply to inherited
test functions. No project configuration changes are needed.

The integration uses the vendored PoolManager and a local ERC-20 at the specified
IMD address. Live mainnet IMD behavior, deployed PoolManager bytecode, and the
launch factory's atomic deployment/allocation remain unverified by this offline
suite. No fork tests were run.
