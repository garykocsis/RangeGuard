# Vendored: reactive-lib-omni (src only)

This is a **vendored copy** of the relevant sources from
[`Reactive-Network/reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
**v0.1.0** (`@3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8`), committed directly into the repo (not a
git submodule) so the project builds on a fresh `git clone` with no submodule init.

Only `src/` is vendored — that is all the `reactive-lib/=lib/reactive-lib-omni/` remapping needs.

## Local modification

The upstream sources are `pragma solidity ^0.8.29`. They have been **relaxed to `^0.8.26`** so the
project compiles on its `0.8.26` toolchain (v4-core's `PoolManager` pins exact `0.8.26`, which
cannot coexist with `^0.8.29` in one compilation unit). The library uses no 0.8.27+ language
features, so this is safe. See `docs/reactive-lib-omni-audit.md` and
`docs/session-12-reactive-deployment.md` for the full rationale.

To re-vendor from upstream later (and re-apply the pragma relax):

```bash
forge install Reactive-Network/reactive-lib-omni   # into a temp, or a submodule
find <upstream>/src -name '*.sol' -exec sed -i '' 's/\^0\.8\.29;/^0.8.26;/' {} +
# then copy <upstream>/src into lib/reactive-lib-omni/src
```
