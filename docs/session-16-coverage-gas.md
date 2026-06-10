# Session 16 — Coverage Report + Gas Snapshot

Branch: `fix/coverage-gas`

This session produced the test-coverage report, the committed gas-snapshot baseline,
README status badges, two new CI jobs (gas-regression check + coverage), and an
`.env.example` template. The only remaining roadmap item after this session is the full
README write-up.

---

## Opening Prompt (verbatim)

> RangeGuard — Session 16: Coverage Report + Gas Snapshot
> Branch: fix/coverage-gas (create before starting)
> Mandatory first steps:
>
> Read project-status.md
> Read CLAUDE.md
> Confirm current state before running anything
>
>
> Task 1 — Gas Snapshot:
> ```bash
> forge snapshot
> ```
> Commit the generated .gas-snapshot file to the repo root
> This file is the baseline — future PRs that increase gas will be caught by CI
>
>
> Task 2 — Coverage Report:
> ```bash
> forge coverage --report summary
> ```
> Capture the summary output
> Create docs/coverage-summary.md with the results formatted cleanly:
>
> ```markdown
> # RangeGuard — Test Coverage Summary
>
> Generated: <date>
> Forge version: <version>
>
> ## Summary
>
> | File | % Lines | % Statements | % Branches | % Functions |
> |------|---------|--------------|------------|-------------|
> | ... | ... | ... | ... | ... |
>
> ## Total
> | Lines | Statements | Branches | Functions |
> |-------|------------|----------|-----------|
> | XX%   | XX%        | XX%      | XX%       |
>
> ## Notes
> - Coverage excludes test files and scripts
> - Fuzz tests run at 1,000 iterations (CI profile: 10,000)
> - Invariant tests run across all state transitions
> ```
>
> Add coverage/ to .gitignore if not already there (HTML report too large to commit)
>
>
> Task 3 — README Badges:
> Add static badges to README.md directly below the tagline line:
> ```markdown
> ![Tests](https://img.shields.io/badge/tests-292%20passing-brightgreen)
> ![Coverage](https://img.shields.io/badge/coverage-XX%25-brightgreen)
> ![License](https://img.shields.io/badge/license-MIT-blue)
> ![Network](https://img.shields.io/badge/network-Sepolia-blue)
> ![Reactive](https://img.shields.io/badge/Reactive%20Network-Lasna-purple)
> ```
> Replace XX with the actual coverage percentage from Task 2.
>
> Task 4 — CI Update:
> Update .github/workflows/ci.yml to add two new jobs after the existing test job:
> ```yaml
> gas-snapshot:
>   name: Gas Snapshot
>   runs-on: ubuntu-latest
>   steps:
>     - uses: actions/checkout@v3
>     - name: Install Foundry
>       uses: foundry-rs/foundry-toolchain@v1
>     - name: Run gas snapshot
>       run: forge sn
>
> coverage:
>   name: Coverage Check
>   runs-on: ubuntu-latest
>   steps:
>     - uses: actions/checkout@v3
>     - name: Install Foundry
>       uses: foundry-rs/foundry-toolchain@v1
>     - name: Run coverage
>       run: forge coverage --report summary
> ```
> Note on forge snapshot --check:
>
> This compares against the committed .gas-snapshot baseline
> Fails if any function's gas increases
> This is the intended behavior — any gas regression gets caught on every PR
>
>
> Session closer:
>
> Update project-status.md — tick coverage + gas snapshot checkbox, record coverage percentage
> Update CLAUDE.md — current session state
> Update context.md Section 2 — remove coverage/gas, add full README as final remaining target
> Generate docs/session-16-coverage-gas.md with: full opening prompt verbatim, coverage summary results, gas snapshot highlights (most expensive functions), CI changes, any deviations  also do not update session closer documents until prompted.

Follow-up prompts in this session (after the opening): (a) add a Production Contract Coverage
section to docs/coverage-summary.md and pull the top-5 production hook functions into this doc;
(b) create an `.env.example` and confirm `.env` is gitignored; (c) write all closing docs now.

---

## Task 1 — Gas Snapshot

- `forge snapshot` generated `.gas-snapshot` at the repo root — the committed baseline that CI
  compares against on every PR via `forge snapshot --check`.
- **277 entries** (the 14 Sepolia fork tests are deliberately excluded — see the decision below).
- Verified: `forge snapshot --check --no-match-path "test/integration/sepolia/*"` exits 0 against
  the committed baseline (no regression).

### Most expensive snapshot entries (per-test, top 5)

| Test | Gas |
|------|-----|
| `SwapIntegration:test_Integration_WhenFeeOverridden_SwapperPaysDerivedFee` | 4,586,812 |
| `ReactiveTickUpdatedTest:test_HandleTickUpdated_WhenManyPositions_NoCap` | 2,794,953 |
| `ReactiveHeartbeatTest:test_HandleHeartbeat_WhenManyDue_CapsAt20` | 2,721,360 |
| `CheckpointAndSeedIntegration:…_SettlesFromSeededCustody` | 2,405,657 |
| `SwapIntegration:test_Integration_WhenSwap_FundsBufferAndUpdatesTick` | 2,354,282 |

---

## Task 2 — Coverage Report

`forge coverage --report summary --no-match-coverage "(test|script)/"` → captured in
`docs/coverage-summary.md` (which also carries a **Production Contract Coverage** section).

| File | % Lines | % Statements | % Branches | % Functions |
|------|---------|--------------|------------|-------------|
| src/RangeGuardHook.sol | 100.00% (244/244) | 99.68% (312/313) | 98.00% (49/50) | 100.00% (29/29) |
| src/RangeGuardReactive.sol | 100.00% (81/81) | 98.86% (87/88) | 100.00% (12/12) | 100.00% (9/9) |
| src/base/AbstractPausableReactive.sol | 92.00% (23/25) | 95.83% (23/24) | 70.00% (7/10) | 85.71% (6/7) |
| src/demo/DemoLPRouter.sol | 100.00% (33/33) | 95.45% (42/44) | 83.33% (10/12) | 100.00% (5/5) |
| src/mocks/MockUSDC.sol | 0.00% (0/4) | 0.00% (0/2) | 100.00% (0/0) | 0.00% (0/2) |
| **Total** | **98.45% (381/387)** | **98.51% (464/471)** | **92.86% (78/84)** | **94.23% (49/52)** |

**Headline: 98.45% line coverage.** The two shipped protocol contracts — `RangeGuardHook.sol`
and `RangeGuardReactive.sol` — are at **100% lines and 100% functions**. The aggregate sits below
100% only because of two intentional, non-shippable items:

- `src/mocks/MockUSDC.sol` — 0%, a TESTNET-ONLY ERC-20 mock (permissionless mint) never deployed
  to mainnet; its helpers run on-chain, not in unit tests.
- `src/base/AbstractPausableReactive.sol` — the uncovered branches are the `vm`/`vmOnly`
  ReactVM-detection guards in the vendored reactive-lib-omni port; they resolve only on the live
  Reactive Lasna runtime and cannot be exercised inside the Foundry EVM.

`coverage/` and `lcov.info` were added to `.gitignore` (HTML report too large to commit).

---

## Gas Efficiency Reference — Top 5 Production Hook Functions

Source: `forge test --gas-report --no-match-path "test/integration/sepolia/*"`.

> Sourcing note: the task said to pull these "from `.gas-snapshot`," but that file only records
> per-*test* gas. Production per-*function* gas comes from the gas report. Figures are from the
> `RangeGuardHookHarness` table — the harness wraps each production callback in a thin `exposed_*`
> external shim, so the numbers are production gas plus a negligible (~few hundred gas) dispatch
> overhead. Ranked by average gas.

| # | Production function | Avg gas | Median | Max | What it does |
|---|---------------------|---------|--------|-----|--------------|
| 1 | `beforeInitialize` | 212,967 | 213,243 | 213,483 | One-time pool bring-up — validates + commits the immutable `PoolConfig` (Phase 2). |
| 2 | `afterAddLiquidity` | 163,872 | 166,743 | 167,151 | Position registration + dt=0 accrual baseline (writes the immutable entry snapshot). |
| 3 | `afterRemoveLiquidity` | 61,922 | 47,463 | 128,896 | Full settlement: final `_accrue` → `_computeIL` → `_computePayout` → strict-CEI payout. |
| 4 | `checkpoint` | 56,455 | 54,476 | 75,386 | Permissionless accrual driver (Reactive entry point); lazy `_accrue` for one position. |
| 5 | `afterSwap` | **46,414** | 47,324 | 81,692 | Notional buffer skim + `TickUpdated` — no accrual, no LP iteration (O(1)). |

Observations:

- The two heaviest functions (`beforeInitialize`, `afterAddLiquidity`) are **one-time-per-pool**
  and **one-time-per-position** respectively — not on any hot path.
- The per-swap cost (`afterSwap`, **46,414** avg) is **constant** regardless of LP count: a single
  buffer credit + `TickUpdated`, never iterating positions (CLAUDE.md "no O(N) LP iteration in
  swap paths").
- Settlement and accrual operate on a **single** position with bounded, deterministic work.
- `beforeSwap` (fee-derivation view, ~4k gas) and `beforeRemoveLiquidity` (validation-only view,
  ~6k gas) are intentionally cheap and touch no accounting state.

---

## Sepolia Fork Exclusion Decision (and why it's correct)

The 14 Sepolia fork tests under `test/integration/sepolia/*` are **excluded from the committed
gas-snapshot baseline** (`forge snapshot --no-match-path "test/integration/sepolia/*"`), and the
CI gas job applies the same exclusion.

Why this is correct — not a coverage gap:

1. **They `vm.skip` without an RPC.** `SepoliaBaseTest` calls
   `vm.skip(true, …)` when `SEPOLIA_RPC_URL` is unset. Locally a `.env` supplies the RPC (so all
   292 tests run, 0 skipped); CI has no `.env`, so these 14 skip. A baseline that includes them
   would never match what CI regenerates → `forge snapshot --check` would fail on every PR for an
   environmental reason, not a real regression.
2. **Their gas is fork-block-dependent.** They run against live Sepolia state at the latest
   forked block, so the same test yields different gas across runs — fundamentally unsuitable for
   a deterministic baseline.

Net: the committed baseline (277 entries, 278 deterministic tests) is reproducible byte-for-byte
in CI, which is exactly what a gas-regression gate requires. The fork tests still run locally
(and in any environment with `SEPOLIA_RPC_URL`) and still count toward the 292 total.

---

## Task 3 — README Badges

Added five static shields.io badges directly below the tagline in `README.md`:

```markdown
![Tests](https://img.shields.io/badge/tests-292%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/coverage-98%25-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)
![Network](https://img.shields.io/badge/network-Sepolia-blue)
![Reactive](https://img.shields.io/badge/Reactive%20Network-Lasna-purple)
```

`XX` was replaced with **98** (the actual line-coverage percentage). Tests badge shows 292 (the
full local suite, matching the deck).

---

## Task 4 — CI Update

Added two jobs to `.github/workflows/ci.yml` after the existing `test` job: `gas-snapshot` and
`coverage`.

Deviations from the literal snippet (for correctness, matching the repo's existing `test` job):

- **`actions/checkout@v4` + `submodules: recursive`** (snippet had `@v3`, no submodules) — the
  build requires submodules; the existing job already uses v4 + recursive.
- **Foundry pinned to `version: "1.3.5"`** (snippet left it unpinned) — gas figures are
  toolchain-sensitive, so the gate must use the same forge version that produced the baseline.
- **`forge snapshot --check --no-match-path "test/integration/sepolia/*"`** instead of bare
  `forge sn`. `--check` is what actually enforces the baseline (the task's own note explains this
  is the intended behavior — fail on any gas increase); `forge sn`/`forge snapshot` alone would
  just regenerate and never fail. The `--no-match-path` mirrors the baseline's fork exclusion.
- The coverage job uses `--no-match-coverage "(test|script)/"` to report production-only coverage.

---

## `.env.example` Addition

Created `.env.example` at the repo root — a copy-to-`.env` template (PRIVATE_KEY, Sepolia +
Reactive RPC URLs, Etherscan key, and the live deployed addresses: hook `0xFead…a7C0`, MockUSDC
`0x04feCef…428CA`, DemoLPRouter `0xEA30…1FEa`, PoolManager `0xE03A…3543`, reactive
`0x5eb9c8C0…Fee1`, PoolId, position key, admin/deployer). Confirmed `.env` is gitignored and
`.env.example` is committable. Two spots in the supplied content arrived garbled and were
cleaned: the Sepolia "Deployed Addresses" header (restored; added `HOOK_ADDRESS` and
`STABLE_TOKEN`, the latter reconstructed from the stray `…c5e52794…428CA` MockUSDC fragment) and
the corrupted "Demo Configuration" header.

---

## Deviations Summary

1. **Gas source for the production-function table** — used `forge test --gas-report`, not
   `.gas-snapshot` (the snapshot is per-test, not per-function). Documented inline.
2. **Sepolia fork tests excluded from the baseline + CI gas check** — required for a deterministic
   gate (skip-without-RPC + fork-block-dependent gas). See the decision section above.
3. **CI jobs hardened beyond the literal snippet** — checkout@v4 + recursive submodules, pinned
   Foundry 1.3.5, `forge snapshot --check`. These make the jobs actually run and actually gate.
4. **`.env.example` content cleaned** where the paste arrived corrupted (two headers + two
   reconstructed addresses).

---

## Verification

- `forge snapshot --check --no-match-path "test/integration/sepolia/*"` → exit 0.
- Full suite: **292 passing, 0 failing** (278 deterministic + 14 Sepolia fork).
- `git check-ignore .env` → ignored; `.env.example` → committable.

## Remaining

- Full README write-up (the single remaining roadmap item).
