# Vendored dependencies

These are ordinary source files, not git submodules. Only the transitive Solidity
imports needed by this project are retained, with upstream license texts. Sources
are unmodified. No build-time dependency installation is required.

| Source | Pinned release/commit | Use | License |
| --- | --- | --- | --- |
| [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/e50237c43811bd9b526eff40f26772152a42daba) | v4.0.0, `e50237c43811bd9b526eff40f26772152a42daba` | Hook types/libraries; real PoolManager for tests | Per-file MIT or BUSL-1.1; texts in `lib/v4-core/licenses/` |
| [OpenZeppelin/openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0) | v5.1.0 | Standard ERC-20, metadata interface; safe test settlement | MIT, `lib/openzeppelin-contracts/LICENSE` |
| [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.6) | v1.9.6 | Test helpers and cheatcode interfaces | MIT / Apache-2.0, `lib/forge-std/LICENSE-*` |
| [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `4b47a19038b798b4a33d9749d25e570443520647`, v4-core's pinned version | PoolManager protocol ownership base in tests only | AGPL-3.0 repository license; Owned.sol SPDX AGPL-3.0-only |

`DEPENDENCIES.sha256` records the exact vendored file contents. The hook does not
deploy a PoolManager, router, ownership base, vault or any dependency contract.
Imported libraries used by the hook are inlined by the compiler.
