# SIMDTEST launch

An immutable SIMDTEST/IMD Uniswap v4 hook launch for Ethereum mainnet. Deploy only
`SIMDTEST` and `SIMDTESTHook`. The application has no owner, administrator, upgrade,
pause, mint-after-construction, token tax, withdrawal, or configuration setter.

## Build and checks

```sh
forge build
forge test
forge fmt --check
python3 script/check_release.py
```

The root configuration pins Solidity **0.8.26**, Cancun, optimizer runs 200 and
`bytecode_hash = "none"`. All Solidity dependencies are ordinary vendored files;
no network, submodules, package installation, environment variables, FFI, filesystem
permissions, or mainnet fork is needed to build or test. Foundry and the pinned
compiler must already be installed. Dependency origins and licenses are recorded
in `DEPENDENCIES.md`; `DEPENDENCIES.sha256` records their contents.

## Token and launch allocation

`SIMDTEST` is the standard OpenZeppelin ERC-20 with name/symbol `SIMDTEST`, 18
decimals and exactly **1,000,000,000 tokens (10^27 base units)**. Its no-argument
constructor mints the entire supply to its deploying launch factory. There are no
additional token entry points beyond ERC-20. Transfers and approvals are untaxed
and have no maximum amount.

The SIMD launch factory is responsible for placing **900,000,000 tokens (90%)**
into the launch pool, supplying the corresponding IMD, and handling the remaining
10% under its launch policy. The token and hook neither choose a recipient nor
deploy a distributor. The integration tests seed exactly the 90% allocation.
LP custody and any liquidity lock are the launchpad's responsibilities; this hook
does not lock positions or guarantee that liquidity cannot be withdrawn.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| PoolManager constructor argument | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Token constructor argument | Actual address of the freshly deployed `SIMDTEST` (`$token`) |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals |
| Pool fee | 12500 millionths = 1.25%, static |
| Tick spacing | 60 |
| Manifest initial price | `79228162514264337593543950336`, provenance only |
| Required hook address bits | `uint160(hook) & 0x3fff == 0x20cc` |

`launch.json` uses kind `univ4_hook`, plain contract names, an explicit permissions
array and a string `notes` field. Resolve `$poolManager` to the mainnet address
above and `$token` to the factory's actual token deployment. These are launchpad
substitutions, not addresses to copy into a live transaction. The hook constructor
is `(IPoolManager manager_, address token_)`; both must have deployed code, and the
token must report the required supply and decimals. IMD is fixed in the hook.
The contract accepts a manager argument so tests can deploy a local v4 manager;
the factory must supply the specified mainnet manager in production.

Deployment sequence for the existing launch factory:

1. Deploy the token to the factory and derive the hook creation bytecode including
   its two ABI-encoded constructor arguments. Mine a CREATE2 salt using the actual
   factory address so the hook's low 14 address bits equal `0x20cc`. The constructor
   independently checks every permission bit. The integration tests demonstrate
   actual CREATE2 mining and deployment with the same constructor.
2. **Atomically deploy the hook, initialize the pool, and seed its liquidity.**
   Sort SIMDTEST and IMD by numeric address. The hook binds its immutable pool ID
   to those currencies, itself, fee 12500 and spacing 60. The factory determines
   the opening price from its launch economics; the manifest price does not
   override them. All this must occur in one transaction, with no untrusted calls
   between hook deployment and initialization. Initialization is permissionless:
   a separate deployment transaction would allow someone else to start the clock
   and choose the opening price. Initialization before hook deployment fails
   because the required callback cannot return its selector.
3. Seed the 90% token allocation with adequate in-range liquidity and IMD before
   exposing swaps. Verify addresses, token transfer behavior, constructor
   arguments, source/bytecode and the initialized pool on mainnet. Supplied chain
   addresses are task inputs; local tests do not verify live IMD behavior.

There is no post-launch configuration, owner handover, maintenance transaction,
fee collector, extra market, or privileged recovery function. No transactions or
key handling are performed by this project.

## Launch protection and accounting

Pool initialization is “open”: let its block be **B** and timestamp be **T**.
The immutable pool binding and one-time initialization prevent resetting clocks
or attaching this hook to a different pool.

| Block offset | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10+ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Extra fee | 30% | 27% | 24% | 21% | 18% | 15% | 12% | 9% | 6% | 3% | 0% |

The opening block counts as the first protected block. The block fee and the
one-hour buy cap are independent. Until `T + 3600` (exclusive), each buy's actual
SIMDTEST output must be at most **10,000,000 tokens (10^25 base units)**. Exactly
the cap is accepted. Both exact-input and exact-output buys are checked. At
exactly `T + 3600`, the cap ends. Sells and token transfers have no buy cap. The
cap is per pool swap, not per wallet, transaction, router, or cumulative volume;
splitting buys is possible. Other pools and transfers are outside its scope.

Every extra fee is IMD. Let `D = 1,000,000` and `r` be the current rate. All
divisions below round down to whole IMD base units:

| Swap | Extra IMD fee | Settlement |
| --- | --- | --- |
| Exact-input buy, gross budget `G` | `floor(G*r/D)` | `beforeSwap` reduces core IMD input by the fee |
| Exact-output buy, actual core IMD cost `N` | `floor(N*r/(D-r))` | `afterSwap` adds the fee to IMD owed |
| Exact-input sell, actual core IMD output `G` | `floor(G*r/D)` | `afterSwap` deducts the fee from IMD received |
| Exact-output sell, requested net IMD `N` | `floor(N*r/(D-r))` | `beforeSwap` increases core IMD output by the fee |

Gross-up makes the rate a fraction of gross paired-currency flow across all four
modes, with less than one base unit of rounding. The unchanged pool LP fee is
charged by v4 on core input. For example, at 30%, a 100 IMD exact-input buy
donates 30 IMD and passes 70 IMD to the normal 1.25%-fee swap. Small fees may
round to zero. No LP fee override or dynamic fee is used.

`afterSwap` calls `PoolManager.donate` for the entire fee in IMD. That creates a
negative hook delta; the positive swap return delta cancels it within the same
unlock. The swapper settles the resulting balance through their router. The
hook never takes, transfers, burns, converts, or retains IMD or SIMDTEST, and
creates no ERC-6909 claims. No native ETH is required.

**Donation increases claimable fees for the liquidity in range after the swap.**
It does not increase v4's numerical position liquidity or compound LP positions.
LPs can collect these assets or reinvest them. Only in-range positions share the
donation. Normal v4 fee-growth rounding can leave sub-unit dust in PoolManager.

### Price limits and partial fills

v4 permits changing only the *unspecified* currency from `afterSwap`. When IMD
is specified (exact-input buys and exact-output sells), a nonzero fee therefore
requires a complete fill of the adjusted core amount. Partial fills revert
atomically with `PartialFillWithSpecifiedFee`, including any pool changes and
fees. This avoids charging a fee for an unfilled portion. During this short
window routers must quote a fillable size and set appropriate slippage bounds.

Exact-output buys and exact-input sells can partially fill: their fee uses actual
IMD exchanged. After B+10, ordinary v4 partial-fill behavior applies to every
mode. If a nonzero donation would land with zero active liquidity, v4 rejects it
and the whole swap reverts. Routers remain responsible for minimum output,
maximum input, deadlines, and ensuring an exact-output request was filled where
their API promises that. Arbitrary `hookData` does not change any rule.

## Validation and limitations

Tests run against the vendored, unmodified v4 PoolManager with a test-only IMD
ERC-20 at the supplied pair address. Both currency orderings are covered. They
check every decay block; all four swap modes; exact cap and one unit over; both
time boundaries; unrestricted large sells and transfers; donation events,
fee-growth, LP collection and out-of-range exclusion; token conservation; empty
hook balances, claims and transient deltas; partial fills; empty/exhausted
liquidity; integer rounding; initialization; CREATE2 bits; unauthorized callbacks;
invalid pools and constructor inputs; fixed token supply; and fuzzed accounting.

The release check verifies the task's manifest fields against the compiled ABIs,
dependency hashes, creation/runtime size limits, and absence of executable
`SELFDESTRUCT`/`DELEGATECALL` in the two launch contracts. It is a local consistency
check, not the launchpad's independent manifest admission service.

No hook state persists between swap callbacks, no external party is called by
the hook during a swap other than its immutable PoolManager, and donate callbacks
are disabled. This avoids a fee-reservation storage/reentrancy dependency. The
only storage writes are the one-time opening clocks. PoolManager itself has
Uniswap protocol governance, including protocol fees; this hook adds no such
powers and cannot remove the underlying protocol's powers. Standard LP/MEV
risks, including just-in-time liquidity receiving donations, remain.

Local build, integration/fuzz tests and bytecode checks are not an independent
security audit. An independent adversarial review and verification of the
factory's atomic launch and allocation remain release responsibilities.
