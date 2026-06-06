# RangeGuard — reactive-lib → reactive-lib-omni Compatibility Audit

**Date:** 2026-06-05
**Branch:** feat/reactive-deployment
**Old lib:** `reactive-lib` v0.2.0 (`lib/reactive-lib`, paths under `src/abstract-base/`)
**New lib:** `reactive-lib-omni` v0.1.0 @ `3ade0dc` (`lib/reactive-lib-omni`, paths under `src/base/`)

> **Headline:** This is a **structural API rewrite**, not a cosmetic bump. Four things changed that the
> contracts depend on directly: (1) the abstract-base directory was renamed, (2) `AbstractPausableReactive`
> was **deleted entirely**, (3) the `LogRecord`/`Subscription` struct fields were **all renamed**
> (`snake_case` → `camelCase`), and (4) the callback/reactive **authentication model was redesigned**
> (`msg.sender` ACL → injected-address check; `vm` auto-detection removed; new `0x8888…8888` system address).

---

## 1. AbstractCallback constructor — old vs new

| | Old (`abstract-base/AbstractCallback.sol`) | New (`base/AbstractCallback.sol`) |
|---|---|---|
| Signature | `constructor(address _callback_sender)` | `constructor(IPayable callbackProxy_, address callbackSender_)` |
| Stored | `rvm_id = msg.sender`; `vendor = IPayable(_callback_sender)`; `addAuthorizedSender(_callback_sender)` | `_SERVICE_PROVIDER = callbackProxy_` (via `AbstractPayer`); `_CALLBACK_SENDER = callbackSender_` |
| Auth modifier | `authorizedSenderOnly` (checks `senders[msg.sender]`, from `AbstractPayer`) **+** `rvmIdOnly(addr)` | `onlyCallbackSender(addr)` (checks `addr == _CALLBACK_SENDER`) **+** `onlyServiceProvider` (checks `msg.sender == _SERVICE_PROVIDER`), both from new bases |
| `addAuthorizedSender` / `senders` ACL | present | **removed** |

**Does RangeGuardHook need updating? YES — it will not compile otherwise**, for three reasons:
1. Import path `reactive-lib/src/abstract-base/AbstractCallback.sol` no longer exists (now `…/base/…`).
2. The 1-arg constructor no longer exists.
3. `authorizedSenderOnly` no longer exists.

**Migration chosen (minimal, behaviour-preserving): use `onlyServiceProvider`.**
The new `onlyServiceProvider` (msg.sender == callback proxy) is the **semantic twin** of the old
`authorizedSenderOnly` (which authorised exactly the callback-proxy address). Both gate on
"called by the proxy". This:
- preserves the live hook's existing auth posture (proxy-as-sender),
- keeps the ignored leading `address` RVM-ID placeholder argument intact (CLAUDE.md forbids removing it),
- keeps all ~110 test call sites (`vm.prank(CALLBACK_PROXY)` + `address(0)` placeholder) green **without
  editing test assertions**.

The alternative — `onlyCallbackSender(rvmId)` (authenticate the *injected reactive-contract address*) — is
the "new recommended" model but would (a) require the hook to know the reactive contract's address at
construction (deploy-ordering / chicken-and-egg), and (b) break every pranking test. Rejected for MVP.
**See the deployment blocker in §13.**

Hook constructor stays 3-arg `(_manager, _owner, _callbackSender)`; internally it now calls
`AbstractCallback(IPayable(_callbackSender), _callbackSender)` — the same proxy address fills both the
service-provider (payment) and callback-sender slots, matching old single-address behaviour.

---

## 2. `emit Callback(...)` — deprecated?

The `Callback` event **still exists** in the new `IReactive` but is explicitly annotated:
*"Deprecated and should not be used for new development. Use the system contract's `requestCallback()` and
`requestCallback_V_*_*()` methods."*

**Replacement:** `SYSTEM.requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0({chainId, recipient, gasLimit, payload}))`.

**Every site in `RangeGuardReactive.sol` using `emit Callback(...)` (3 total):**
| Line | Handler | Payload selector |
|---|---|---|
| 251 | `_handleTickUpdated` (in→out) | `checkpointAndEmitOutOfRange(address,bytes32,bytes32)` |
| 259 | `_handleTickUpdated` (out→in) | `checkpointAndEmitBackInRange(address,bytes32,bytes32)` |
| 299 | `_handleHeartbeat` | `checkpointCallback(address,bytes32,bytes32)` |

All three migrate to `SYSTEM.requestCallbackV_1_0(...)`, preserving `chainId = hookChainId`,
`recipient = hookAddress`, `gasLimit = CALLBACK_GAS_LIMIT`, and the **`address(0)` first-arg placeholder**
in each payload (CLAUDE.md mandate). Business logic (range detection, heartbeat gating, position tracking)
is untouched.

---

## 3. AbstractPausableReactive — changed?

**Deleted entirely.** The new lib has **no** `AbstractPausableReactive.sol`. It provided `owner`,
`paused`, `onlyOwner`, `pause()`, `resume()`, `getPausableSubscriptions()`, and the `Subscription` struct
— all of which `RangeGuardReactive` and its tests depend on.

**Migration:** port a local `AbstractPausableReactive` into the repo
(`src/base/AbstractPausableReactive.sol`) as a verbatim behavioural copy adapted to the new
`AbstractReactive` (new `SYSTEM` address, `onlySystem`, new `IReactive`). This keeps `RangeGuardReactive`'s
inheritance, `getPausableSubscriptions()` override, pause/resume behaviour, and all pause/resume tests
identical. The local base also re-introduces the `vm` flag + `detectVm()` + `rnOnly`/`vmOnly` (see §6/§7)
so the `if (!vm)` constructor guard and `vmOnly`-gated `react()` keep working unchanged.

---

## 4. `react()` / LogRecord struct — fields renamed

`react(LogRecord calldata)` signature is unchanged, but **every `LogRecord` field was renamed**
(`snake_case` → `camelCase`):

| Old field | New field | Used in RangeGuardReactive? |
|---|---|---|
| `chain_id` | `chainId` | builders only |
| `_contract` | `contractAddress` | **yes** — `react()` routing (`log._contract == address(service)`) |
| `topic_0` | `topic0` | **yes** — routing + handlers |
| `topic_1` | `topic1` | **yes** — `_handle*` (poolId) |
| `topic_2` | `topic2` | **yes** — `_handle*` (positionKey) |
| `topic_3` | `topic3` | builders only |
| `data` | `data` | **yes** (unchanged name) |
| `block_number`/`op_code`/`block_hash`/`tx_hash`/`log_index` | `blockNumber`/`opCode`/`blockHash`/`txHash`/`logIndex` | no |

The `Subscription` struct (now defined in the ported local base) keeps the same field names as the old lib
(`chain_id`, `_contract`, `topic_0..3`) since it is **our** struct — no churn there.

**Every field currently read in `RangeGuardReactive.sol`** → rename required:
`log._contract` (1×, line 163), `log.topic_0` (3×, lines 165/167/169), `log.topic_1` (3×, lines 203/233/271),
`log.topic_2` (2×, lines 204/272), `log.data` (3×, lines 207/234 — name unchanged).

Test builders in `ReactiveTestBase.t.sol` (`_log`, `_registeredLog`, `_tickLog`, `_closedLog`, `_cronLog`)
construct `IReactive.LogRecord` by field — all field assignments rename too (harness infra, not assertions).

---

## 5. REACTIVE_IGNORE — still available?

**Yes, unchanged value, relocated.** Old: `AbstractReactive` (`abstract-base`). New: `AbstractReactive`
(`base`), same constant
`0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad`. Inherited transitively by
`RangeGuardReactive` via the ported pausable base → `AbstractReactive`. No code change.

---

## 6. vmOnly modifier — still available?

**No — renamed/removed.** New `AbstractReactive` provides `onlySystem` (msg.sender == SYSTEM) instead of
`vmOnly`; `rnOnly` is gone too. `react()` currently uses `vmOnly`.
**Migration:** the ported local base re-declares `vm`/`detectVm()`/`vmOnly`/`rnOnly` (verbatim from old lib,
but probing the new `0x8888…8888` system address) so `react() … vmOnly` and the `rnOnly` pause/resume
guards keep working unchanged. (Equivalent alternative: switch `react()` to `onlySystem`; rejected to keep
the harness's direct-handler-call test pattern and pause/resume tests untouched.)

---

## 7. vm flag — still available for `if (!vm)` guards?

**No** — `AbstractReactive` no longer declares `vm` or `detectVm()`. The constructor's
`if (!vm) { …subscribe… }` guard (which lets local Foundry deploys skip subscriptions) has no lib support.
**Migration:** re-introduced in the ported local base (§3/§6), probing `0x8888…8888`. Behaviour identical:
`vm == true` in plain Foundry (no system contract) → subscriptions skipped; `vm == false` once a mock is
etched there.

---

## 8. System contract address — which does the new lib use?

**New: `0x8888888888888888888888888888888888888888`** (`AbstractReactive.SYSTEM`).
The old `0x0000…fffFfF` (`SERVICE_ADDR`) is **gone** from `AbstractReactive`. Consequences:
- `service.subscribe(...)` → `SYSTEM.subscribe(...)` (the `service` field no longer exists; use the
  `SYSTEM` constant). Affected: 4 constructor subscriptions + `getPausableSubscriptions()` + the `react()`
  heartbeat routing check `log.contractAddress == address(SYSTEM)`.
- The Cron subscription source (`address(service)` for `block.chainid`) → `address(SYSTEM)`.
- Tests must etch the `MockSystemContract` at `0x8888…8888` (not `0x…fffFfF`).

> Note: `0x…fffFfF` is **separately** still the **callback-proxy** address on the host chain (§9/§10) — a
> different role from the reactive-network system contract. Don't conflate them.

---

## 9. Callback proxy address — `0x…fffFfF` still valid for `_callbackSender` on the hook?

**Library-side: unconfirmed; network-specific — must be verified against Lasna/Sepolia docs (BLOCKER).**
Nothing in the lib hard-codes the host-chain callback proxy; it's a constructor input. The live hook on
Sepolia was deployed with `_callbackSender = 0x0000000000000000000000000000000000fffFfF` and authenticates
callbacks as `msg.sender == that address`. **For the demo to work, the Lasna→Sepolia callback proxy must
call the hook FROM `0x…fffFfF`.** If the Omni network changed the Sepolia-side callback-proxy address, the
**already-deployed hook would reject every callback** and could not be fixed without redeploying (which the
task forbids). **This must be confirmed before deployment — see §13, Blocker B.**

---

## 10. vmOnly / system vs proxy summary

- ReactVM system contract (subscriptions, `requestCallbackV_1_0`, react routing): **`0x8888…8888`** (new).
- Host-chain callback proxy (calls the hook; payments): **`0x…fffFfF`** historically — **confirm for Lasna**.

---

## 11. DeployRangeGuardReactive.s.sol — values to update

| Item | Current | New (Lasna) |
|---|---|---|
| RPC URL | `$REACTIVE_RPC_URL` (Kopli) | `https://lasna-omni-rpc.rnk.dev/` |
| Reactive chain id (doc constant in `RangeGuardReactive`) | `5318007` | `5318007` (Lasna — already correct ✓) |
| `HOOK_CHAIN_ID` default | `11155111` | `11155111` ✓ |
| `HOOK_ADDRESS` | env | `0x50cd0E7e046022a9B359ca8725aCb75748FB67C0` |
| `CRON_TOPIC` | env | `0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687` (Cron10) |
| `MIN_CHECKPOINT_INTERVAL` default | `120` | `120` ✓ |
| `RGAS_FUND_AMOUNT` / `--value` | `0.01 ether` | **recompute from reactiveSpec §13.5 for 48 h** (BLOCKER C) |
| `PRIVATE_KEY` | Anvil fallback | **real deployer key (user-supplied)** |

The contract itself runs on ReactVM, so the script still broadcasts to the Reactive RPC (now Lasna). No
CREATE2/HookMiner (correct — reactive has no hook-flag address constraint).

---

## 12. Test harness — interface changes that break tests

| File | Breakage | Fix (harness infra only) |
|---|---|---|
| `test/harness/MockSystemContract.sol` | etched at `0x…fffFfF`; no `requestCallbackV_1_0` | etch at `0x8888…8888`; add `requestCallbackV_1_0(config)` that **emits the legacy `Callback` event** so existing `_countCallbacks`/`expectEmit` assertions pass unchanged; keep `subscribe`/`unsubscribe`/`debt` |
| `test/shared/ReactiveTestBase.t.sol` | `IReactive.LogRecord` built with `snake_case` fields; `_cronLog` uses `exposed_service()` | rename to `camelCase` fields; route Cron log `contractAddress` to `address(SYSTEM)` |
| `test/harness/RangeGuardReactiveHarness.sol` | `exposed_service()` returns `service`; `exposed_vm()` reads `vm`; `exposed_paused()` reads `paused` | `service` → `SYSTEM`; `vm`/`paused` now from ported local base (still present) — keep |
| `test/unit/ReactivePauseResume.t.sol` | `SERVICE_ADDR = 0x…fffFfF` etch target | → `0x8888…8888` (etch location is infra, not an assertion) |
| All other reactive tests | go through the `ReactiveTestBase` builders | no change once builders fixed |
| Hook tests (`Checkpoint*`, `RangeEvent*`, `Authorization*`) | prank `CALLBACK_PROXY` + `address(0)` placeholder | **no change** — `onlyServiceProvider` (msg.sender==proxy) preserves this exactly |

Goal unchanged: **278 passing, 0 failing** with only harness/infra edits.

---

## 13. Deployment blockers (need user / network confirmation before Phase 5–7)

**A. Deployer secret + funded account.** Phases 6 needs a real `PRIVATE_KEY` and its deployer address
(for the lREACT faucet `request(address)` call and the broadcast). Not available to the agent.

**B. Sepolia-side callback-proxy address on Omni/Lasna (CRITICAL).** The live hook
(`0x50cd…67C0`) authenticates callbacks as `msg.sender == 0x…fffFfF`. If Omni's Sepolia callback proxy is a
different address, **the live hook rejects all callbacks** and the in/out-of-range + heartbeat demo
(Phase 7) cannot complete without redeploying the hook (forbidden). Must confirm the Lasna callback-proxy
address for destination chain 11155111.

**C. rGas (`--value`) for 48 h.** Needs the per-callback rGas figure from reactiveSpec §13.5 ×
(heartbeat cadence 120 s over 48 h ≈ 1,440 cycles + range-transition headroom). Will compute once §13.5 is
read; flag if the demo budget exceeds a sensible cap.

**D. `0x8888…8888` system contract presence on Lasna.** The migrated reactive contract's constructor calls
`SYSTEM.subscribe(...)` (no more `if(!vm)` skip on a real network). Confirm the Lasna ReactVM exposes the
system contract at `0x8888…8888` so deployment subscriptions succeed.

---

## 13a. Research-confirmed Lasna facts + redeploy decision (2026-06-05)

Verified against `dev.reactive.network/origins-and-destinations` (authoritative per-chain table), cross-checked:

| Item | Confirmed value |
|---|---|
| Lasna RPC / chain ID | `https://lasna-omni-rpc.rnk.dev/` · `5318007` |
| **Lasna system contract** (`SYSTEM`) | **`0x8888888888888888888888888888888888888888`** — ✅ matches the new lib. Blocker D cleared. |
| Sepolia lREACT faucet | `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` · 1 ETH → 100 lREACT (≤5 ETH) |
| **Sepolia callback proxy (Lasna→Sepolia destination)** | **`0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA`** |

**Blocker B = confirmed real.** The Omni fork moved the Sepolia callback proxy off the legacy `0x…fffFfF`
to `0xc9f36411…0D7bDA`. The live hook `0x50cd…67C0` authorizes only `0x…fffFfF` and its auth is
**immutable** (no setter) — so it rejects every Lasna callback. **User decision: REDEPLOY the hook**
for Lasna. `DeployRangeGuardHook.s.sol` `CALLBACK_SENDER` updated `0x…fffFfF` → `0xc9f36411…0D7bDA`;
new constructor args ⇒ fresh CREATE2 salt ⇒ **new hook address ⇒ new PoolId ⇒ re-seed buffer**. MockUSDC
`0x04feCef5…428CA` is reused (plain ERC20). This intentionally supersedes the original
"do not redeploy the hook" carry-in, which assumed the proxy was still `0x…fffFfF`.

## Change inventory (files to touch in Phases 2–4)

**src:**
- `src/RangeGuardHook.sol` — import path; `AbstractCallback(IPayable(_callbackSender), _callbackSender)`;
  `authorizedSenderOnly` → `onlyServiceProvider` (3 functions); doc-comment wording.
- `src/RangeGuardReactive.sol` — import the ported pausable base; `service` → `SYSTEM`; `LogRecord` field
  renames; 3× `emit Callback` → `SYSTEM.requestCallbackV_1_0`; keep `vmOnly`/`if(!vm)` via ported base.
- `src/base/AbstractPausableReactive.sol` — **NEW** local port (pausable + vm-detect, on `0x8888…8888`).

**test:**
- `test/harness/MockSystemContract.sol`, `test/shared/ReactiveTestBase.t.sol`,
  `test/harness/RangeGuardReactiveHarness.sol`, `test/unit/ReactivePauseResume.t.sol`.

**infra:** `remappings.txt` (done), `.gitmodules` (done via forge), `foundry.toml` (evm/solc unchanged;
new lib pragma is `^0.8.29` but our `solc 0.8.26` compiles `>=`-pragma'd local contracts — verify at build).

> ⚠️ **`solc_version` — RESOLVED (lib pragma relaxed, project stays on 0.8.26).** New lib files were
> `pragma ^0.8.29`. Bumping the project to 0.8.30 was attempted first but **fails**: v4-core
> `PoolManager.sol` is pinned to exact `pragma solidity 0.8.26;`, and the test contracts import both
> `PoolManager` (=0.8.26) and the hook (which pulls in the new lib, ≥0.8.29) **in one compilation unit**
> — unsatisfiable at any single version. Since reactive-lib-omni uses **no 0.8.27+ language features**
> (verified: no transient storage / mcopy / require-with-custom-error), the fix is to relax the new
> lib's 8 source files from `^0.8.29` to `^0.8.26`. The whole project then compiles on its original
> **0.8.26** toolchain — which also keeps the source consistent with the already-deployed hook's 0.8.26
> bytecode. Our 3 exact-`0.8.26` src pragmas were softened to `^0.8.26` for tidiness but no project
> `solc_version` change is needed.
>
> ✅ **Reproducibility (resolved):** `reactive-lib-omni` is **vendored** — its `src/` is committed
> directly into `lib/` (NOT a git submodule, matching `forge-std`/`v4-hooks-public`), so the `^0.8.26`
> pragma relaxation persists on a fresh clone and the build works with no submodule init / no sed.
> Re-apply the one-liner only if re-vendoring from upstream:
> `find lib/reactive-lib-omni/src -name '*.sol' -exec sed -i '' 's/\^0\.8\.29;/^0.8.26;/' {} +`
> (see `lib/reactive-lib-omni/VENDORED.md`)

> ✅ **Hook auth revert string → custom error.** A consequence of `authorizedSenderOnly` →
> `onlyServiceProvider`: the unauthorized-caller revert changed from the string `"Authorized sender only"`
> to the typed error `NotAuthorized(caller, _SERVICE_PROVIDER)`. The 3 hook access-control tests
> (`CheckpointCallback`, `CheckpointAndEmitOutOfRange`, `CheckpointAndEmitBackInRange`) were updated to
> expect the new error — same category of API-surface assertion change as the §12 emitter pins.
