# Session 10 — Reactive Network Contract Complete

Last completed: RangeGuardHook reactive retrofit (Workstream 1) + RangeGuardReactive.sol
(Workstream 2). **278 tests passing, 0 failing.**

---

## Summary

This session completed the Reactive Network automation layer in two workstreams:

- **Workstream 1** retrofitted `RangeGuardHook` to be driven by the Reactive Network via
  `AbstractCallback` (`authorizedSenderOnly`), replacing the abandoned per-pool
  `reactiveContract`/`setReactiveContract` registration model.
- **Workstream 2** added `RangeGuardReactive.sol` — an `AbstractPausableReactive` contract on
  ReactVM that subscribes to hook events + a Cron heartbeat, tracks per-position range status,
  and dispatches checkpoint callbacks back to the hook.

`reactive-lib` (v0.2.0) was installed and `remappings.txt` added
(`reactive-lib/=lib/reactive-lib/`). Both spec docs were reconciled to the implementation.

---

## Workstream 1 — Hook retrofit (`src/RangeGuardHook.sol`)

- Inherits `BaseHook` **and** `AbstractCallback`. Constructor gains a third arg:
  `constructor(IPoolManager _manager, address _owner, address _callbackSender)`
  (`_callbackSender = 0x…fffFfF`, the Callback Proxy, registered by `AbstractCallback` as the
  sole `authorizedSenderOnly` caller).
- **Removed:** `reactiveContract[poolId]`, `_reactiveSet[poolId]`, `setReactiveContract()`,
  the `ReactiveContractSet` event, and the `ZeroReactive`/`ReactiveAlreadySet` errors.
- **New state:** `mapping(PoolId => mapping(bytes32 => bool)) internal _lastRangeEventInRange`,
  initialized in `afterAddLiquidity` from the entry tick vs `[tickLower, tickUpper)`.
- **New events:** `PositionOutOfRange`, `PositionBackInRange`
  `(poolId, positionKey, tickLower, tickUpper, currentTick, earnedCoverageStable, timestamp)`;
  `PositionClosed(poolId, positionKey, owner)` emitted on **all four** settlement paths.
- **New errors:** `PositionAlreadyOutOfRange`, `PositionAlreadyInRange`.
- **New functions (all `authorizedSenderOnly`, leading ignored `address` RVM-ID placeholder):**
  - `checkpointCallback(address, PoolId, bytes32)` — rate-limited; same gates/effects as
    `checkpoint()` (`_poolInitialized → PositionNotActive → CheckpointTooSoon → _accrue →
    Checkpointed`).
  - `checkpointAndEmitOutOfRange(address, PoolId, bytes32)` — NOT rate-limited; guards
    `PositionNotActive → PositionAlreadyOutOfRange`; atomic accrue + flag→false +
    `PositionOutOfRange`.
  - `checkpointAndEmitBackInRange(address, PoolId, bytes32)` — symmetric; guards
    `PositionNotActive → PositionAlreadyInRange`; flag→true + `PositionBackInRange`.
- Deploy script (`DeployRangeGuardHook.s.sol`) updated with the third constructor arg in both
  the `HookMiner.find` args and the `new` call (`CALLBACK_SENDER` constant).
- `RangeGuardHookHarness` keeps its 2-arg constructor (injects the Callback Proxy constant);
  `exposed_reactiveSet` → `exposed_lastRangeEventInRange`.

## Workstream 2 — `src/RangeGuardReactive.sol`

- `contract RangeGuardReactive is AbstractPausableReactive` (IReactive inherited transitively).
- Constructor: `(address _hookAddress, uint256 _hookChainId, uint256 _cronTopic,
  uint256 _minCheckpointInterval) payable` — four `if (!vm)` subscriptions (Cron on
  `block.chainid`/`address(service)`; three hook events on `_hookChainId`/`_hookAddress`).
- `react(LogRecord) external override vmOnly` routes by source: a log from `address(service)`
  → heartbeat; otherwise dispatch on `topic_0` to the three hook handlers.
- `getPausableSubscriptions()` returns **only** the Cron subscription (heartbeat is pausable;
  hook subscriptions stay live).
- `PositionInfo { bytes32 poolId; int24 tickLower; int24 tickUpper; bool lastKnownInRange;
  bool active; uint256 lastCheckpointTime; }`; `positions` mapping + `activeKeys` (swap-and-pop).
- Handlers per reactiveSpec §10–§13. `MAX_POSITIONS_PER_CYCLE = 20` (heartbeat cap; transition
  detection uncapped); `CALLBACK_GAS_LIMIT = 300_000`; `address(0)` first arg in every payload.

---

## Key decisions / deviations from the locked spec

- **`hookChainId` parameterization (mid-session change, user-approved).** The locked 3-arg
  constructor became 4-arg: the host chain is now a constructor parameter (`hookChainId`,
  immutable) used as both the subscription source chain and the Callback destination, replacing
  the hardcoded `SEPOLIA_CHAIN_ID` constant. spec.md §8 and reactiveSpec.md §2/§6/§7/§8/§9 were
  updated accordingly.
- **Testability visibility.** `_lastRangeEventInRange` and the three `topic0` constants are
  `internal` (spec said `private`) so the harness can assert the range-guard alternation and
  verify topic0s against the hook's real events. Production surface is unchanged.
- **License/pragma.** `RangeGuardReactive.sol` uses `MIT` / `pragma 0.8.26` to match the project
  (reactiveSpec §9.2 suggested `GPL-2.0-or-later` / `>=0.8.0`). Left as a noted, harmless choice.
- **`authorizedSenderOnly` revert string.** From `AbstractPayer`, reverts with the string
  `"Authorized sender only"` (not a custom error) — negative-auth tests assert on that string.

## reactive-lib facts verified against source (v0.2.0)

- `LogRecord` fields: `chain_id, _contract, topic_0…topic_3 (uint256), data, block_number,
  op_code, block_hash, tx_hash, log_index` — **no `block_timestamp`**; topics are `uint256`.
- `authorizedSenderOnly` lives in `AbstractPayer`; `AbstractCallback` registers the Callback
  Proxy in the `senders` ACL. **No `owner` clash** with the hook's immutable `owner`; the
  `AbstractCallback` constructor is **not payable**; `AbstractPayer` adds a `payable receive()`.
- In Foundry `vm == true` (no system contract), so `react()` is callable and the `if (!vm)`
  subscription block is skipped. `pause()/resume()` are `rnOnly` (require `vm == false`) — tested
  via an **etched mock system contract** at `0x…fffFfF`.

## New infrastructure

- `lib/reactive-lib` (v0.2.0) + `remappings.txt` (`reactive-lib/=lib/reactive-lib/`).
- `script/DeployRangeGuardReactive.s.sol` — deploys to ReactVM (not the host chain); env-driven
  (`HOOK_ADDRESS`, `CRON_TOPIC` required; `HOOK_CHAIN_ID`/`MIN_CHECKPOINT_INTERVAL`/
  `RGAS_FUND_AMOUNT`/`PRIVATE_KEY` optional). No CREATE2/HookMiner (no address-flag constraint);
  `--value` funds initial rGas. Dry-run verified. `HelperConfig` intentionally not extended
  (a ReactVM deploy has no host-chain Uniswap dependency).
- Test harnesses: `RangeGuardReactiveHarness` (exposes internal handlers + `service`/`vm`/`paused`
  + topic0 getters), `MockSystemContract` (etched for the pause/resume path), `ReactiveTestBase`
  (LogRecord builders + event mirrors + Callback counter).

---

## Tests

Baseline 210 → pruned 10 obsolete `setReactiveContract`/`ReactiveSet*` tests → **200** →
added **78** → **278 passing, 0 failing**.

**Workstream 1 (+35):** 30 unit (`CheckpointCallback`, `CheckpointAndEmitOutOfRange`,
`CheckpointAndEmitBackInRange`, `LastRangeEventInRange` A/B/C + boundaries, `PositionClosed`
×4 paths) + 2 fuzz (guard alternation; init predicate) + 3 invariant (`AuthorizationInvariant`:
reactive fns only via Callback Proxy, guard alternation, position never deactivated).

**Workstream 2 (+43):** 40 unit (`ReactivePositionRegistered`, `ReactiveTickUpdated` incl.
no-cap + chain-id param, `ReactiveHeartbeat` incl. cap@20, `ReactivePositionClosed`,
`ReactiveReactRouting`, `ReactivePauseResume` via etched mock, `ReactiveTopicWiring`) + 2 fuzz
(`lastKnownInRange` tracking) + 1 integration (`CoverageAccrualLifecycle`).

**Integration (closes Phase 3 gap):** `CoverageAccrualLifecycle` drives both contracts with a
faithful Callback-Proxy relay — register → heartbeat → range-out → range-back-in → heartbeat →
close — asserting monotonic accrual, guard flips on both sides, a real `ClaimSettled` payout,
and empty `activeKeys` after close.

---

## Docs reconciled this session

- **spec.md** §8: Callback snippets use `hookChainId`; deployment note → 4-arg; two typos fixed.
- **reactiveSpec.md** §2 (LogRecord fields), §6/§7/§9 (`hookChainId` replaces `SEPOLIA_CHAIN_ID`,
  4-arg constructor, deploy command, immutable), §8.5 (`topic0` → `internal`).
- **context.md** §2, **project-status.md**, **CLAUDE.md** (this closer).

## Carry-ins for next session (Sepolia/ReactVM deployment)

- Next order: **Sepolia/ReactVM deployment** (hook → Sepolia, Reactive → ReactVM; deploy scripts
  ready — live Cron + rGas funding next session) → **demo script** (RangeGuardDemo.s.sol, run
  against live Sepolia to populate event history) → **frontend dashboard** (renders from Sepolia
  events).
- Before deploying, confirm the Cron topic value, the rGas funding amount, and the Callback Proxy
  address on the target network (reactiveSpec §18.3 / §18.7 / §18.9).
- Payout recipient = v4 `sender` (owner=sender MVP).
- The reactive contract emits ReactVM-side events (`PositionTracked`, `RangeTransitionDetected`,
  `HeartbeatCheckpointFired`, `PositionUntracked`); the coverage report renders from hook-side
  events (`PositionRegistered`, `AccrualUpdated`, `PositionOutOfRange`/`BackInRange`,
  `ClaimSettled`/`PartialPayout`/`NoClaim`/`PositionClosed`).
