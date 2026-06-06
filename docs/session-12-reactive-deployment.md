# Session 12 — reactive-lib-omni Migration + ReactVM Deployment on Lasna

**Date:** 2026-06-05 → 2026-06-06
**Branch:** `feat/reactive-deployment`
**Outcome:** Migrated the reactive stack from `reactive-lib` v0.2.0 to `reactive-lib-omni`
v0.1.0 (Reactive **Omni fork**), redeployed the hook for Lasna compatibility, and deployed the
`RangeGuardReactive` contract live on Reactive **Lasna**. 278 tests passing. The end-to-end
callback round-trip itself was **not** exercised — it needs the demo script (next phase).

---

## 1. Why this session happened

The Reactive Network released the **Omni fork** (Lasna testnet); **Kopli is deprecated**. The
new `reactive-lib-omni` is a structural API rewrite that the existing code depended on. Before
any ReactVM deployment, the codebase had to be audited and migrated.

Mid-session, research against the authoritative Reactive docs surfaced a hard blocker: the Omni
fork **changed the host-chain callback proxy**, and the already-deployed hook's auth is
immutable — forcing a hook redeploy (an authorized deviation from the original "do not redeploy
the hook" constraint). See §5.

---

## 2. Compatibility audit (full report: `docs/reactive-lib-omni-audit.md`)

The migration was **not** cosmetic. Breaking changes in `reactive-lib-omni`:

| Area | Old (`reactive-lib` v0.2.0) | New (`reactive-lib-omni` v0.1.0) |
|---|---|---|
| Source layout | `src/abstract-base/` | `src/base/` |
| `AbstractPausableReactive` | provided by lib | **DELETED** → ported locally to `src/base/` |
| `AbstractCallback` ctor | `(address callbackSender)` | `(IPayable callbackProxy, address callbackSender)` |
| Hook auth modifier | `authorizedSenderOnly` (msg.sender ACL) | `onlyServiceProvider` (msg.sender == proxy) |
| Callback dispatch | `emit Callback(...)` | `SYSTEM.requestCallbackV_1_0(CallbackConfiguration_V_1_0{...})` |
| `LogRecord` fields | snake_case (`_contract`, `topic_0…3`) | camelCase (`contractAddress`, `topic0…3`) |
| System contract | `service` @ `0x…fffFfF` | `SYSTEM` @ `0x8888888888888888888888888888888888888888` |
| `vm` / `detectVm` / `vmOnly` / `rnOnly` | in `AbstractReactive` | removed → restored in the local port |
| `REACTIVE_IGNORE` | present | present (unchanged value) |

**Decisions taken (documented in the audit):**
- **Hook auth → `onlyServiceProvider`** (not the new `onlyCallbackSender(rvmId)`): it is the
  semantic twin of the old model (gate on "called by the proxy"), keeps the hook constructor
  3-arg, and kept ~110 pranking tests green. The same proxy address fills both `AbstractCallback`
  constructor slots: `AbstractCallback(IPayable(payable(_callbackSender)), _callbackSender)`.
- **Dispatch → `requestCallbackV_1_0`** (user-confirmed): the deprecated `emit Callback` still
  exists but is not used. The test harness adapts (see §3).
- **solc stays 0.8.26** (see §6 deviation).

---

## 3. Every changed file and why

### Production source (`src/`)
- **`src/RangeGuardHook.sol`** — import path → `base/` + `IPayable`; constructor →
  `AbstractCallback(IPayable(payable(_callbackSender)), _callbackSender)`; `authorizedSenderOnly`
  → `onlyServiceProvider` (3 reactive-callable functions); doc comments. *No accounting logic
  changed.*
- **`src/RangeGuardReactive.sol`** — import the local pausable port + `ISystemContract`;
  `service` → `SYSTEM`; `LogRecord` field renames (`_contract`/`topic_N` → `contractAddress`/
  `topicN`); 3× `emit Callback(...)` → `SYSTEM.requestCallbackV_1_0(...)`. *No business logic
  (range detection / heartbeat / tracking) changed.*
- **`src/base/AbstractPausableReactive.sol`** — **NEW.** Local port of the deleted upstream base:
  `Subscription` struct, `owner`/`paused`, `onlyOwner`/`pause()`/`resume()`,
  `getPausableSubscriptions()`, and restored `vm`/`detectVm()` (probing `0x8888…8888`) +
  `vmOnly`/`rnOnly`. Built on the new `AbstractReactive`.
- **`src/mocks/MockUSDC.sol`** — pragma `0.8.26` → `^0.8.26` (toolchain tidy).

### Tests (`test/`) — harness infra + dispatch-mechanism assertions only
- **`test/harness/MockSystemContract.sol`** — added `requestCallbackV_1_0(...)` that **re-emits
  the legacy `Callback` event** (so existing `_countCallbacks` / `expectEmit` log-matching still
  works); kept `subscribe`/`unsubscribe`/`debt`.
- **`test/shared/ReactiveTestBase.t.sol`** — `LogRecord` builders → camelCase; etch the mock at
  `SYSTEM` (`0x8888…8888`) **after** constructing the harness (so `detectVm` caches `vm == true`,
  keeping `react()` callable while the mock is present for dispatch); added `SYSTEM_ADDR`.
- **`test/harness/RangeGuardReactiveHarness.sol`** — `service` → `SYSTEM`.
- **`test/unit/ReactiveTickUpdated.t.sol`, `ReactiveHeartbeat.t.sol`,
  `test/integration/CoverageAccrualLifecycle.t.sol`** — the ~7 `Callback` `expectEmit` emitter
  pins flipped from `address(reactive)` → `SYSTEM_ADDR` (the mock is now the emitter); builder
  field renames; etch the mock.
- **`test/unit/CheckpointCallback.t.sol`, `CheckpointAndEmitOutOfRange.t.sol`,
  `CheckpointAndEmitBackInRange.t.sol`** — the unauthorized-caller assertion changed from the
  string `"Authorized sender only"` → the typed error
  `NotAuthorized(caller, _SERVICE_PROVIDER)` (consequence of `onlyServiceProvider`).
- **`test/unit/ReactivePauseResume.t.sol`** — import `AbstractPausableReactive` from the local
  `src/base/`; etch/service address `0x…fffFfF` → `0x8888…8888`.

### Scripts & config
- **`script/DeployRangeGuardHook.s.sol`** — `CALLBACK_SENDER` `0x…fffFfF` →
  `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` (Lasna→Sepolia proxy). New ctor args ⇒ new mined
  salt/address.
- **`script/DeployRangeGuardReactive.s.sol`** — Lasna defaults baked in (RPC, Cron10 topic, new
  hook default, `RGAS_FUND_AMOUNT` 0.05 lREACT, header docs).
- **`remappings.txt`** — `reactive-lib/=lib/reactive-lib-omni/`.
- **`.gitmodules` / `lib/`** — removed `reactive-lib`; brought in `reactive-lib-omni` (v0.1.0
  `@3ade0dc`) and relaxed its 8 source files `^0.8.29` → `^0.8.26` (see §6). It was first installed
  as a git submodule, then **VENDORED** — its `src/` committed directly into `lib/reactive-lib-omni/`
  and the submodule removed (so `.gitmodules` is deleted and the repo has **zero** submodules,
  matching how `forge-std`/`v4-hooks-public` are already tracked). This makes a fresh `git clone`
  build with no submodule init and no manual pragma step. Added `lib/reactive-lib-omni/VENDORED.md`
  (records upstream version + the pragma modification + how to re-vendor). See §9.
- **`Makefile`** — refreshed to match reality: removed the stale `install` target (deps are now
  vendored), added the full deploy/ops runbook as targets — `deploy-hook[-dry]`, `mint-usdc`,
  `stage-init-seed`, `faucet`, `deploy-reactive[-dry]`, `reactive-balance`, `reactive-paused`,
  `reactive-topup`, `reactive-pause`, `reactive-resume` — with the Session-12 live addresses as
  overridable defaults.
- **`foundry.toml`** — unchanged (solc stayed 0.8.26).

### Docs reconciled
`spec.md`, `reactiveSpec.md`, `project-status.md`, `context.md`, `CLAUDE.md`,
`testing-strategy.md`, `invariant-mapping.md`. `state-machine.md` reviewed — **no change needed**
(it has no reactive-API surface, only lifecycle states). New: `docs/reactive-lib-omni-audit.md`,
this file.

---

## 4. Deployed addresses & transactions

**Reactive Lasna** (Omni fork) — RPC `https://lasna-omni-rpc.rnk.dev/` · chainId `5318007` ·
explorer `https://lasna-omni.reactscan.net/` · system contract `0x8888…8888` · faucet (Sepolia)
`0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` (1 ETH → 100 lREACT).

| Component | Address / value |
|---|---|
| **RangeGuardReactive** (Lasna) | `0xC0e6b70c8FF75962541183fdc247E7B07AD6B70b` |
| Reactive deploy tx (Lasna) | `0xed865d580eef19d972436d4e9c9cce40b7359ef393dd3967c9a280e8a22f5329` (block 3790561) |
| Reactive rGas funding | `0.05 lREACT` (in the contract) |
| **RangeGuardHook (new, Sepolia)** | `0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0` (salt `0x…3aee`) |
| **PoolId (new)** | `0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a` |
| MockUSDC (token1, reused) | `0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA` |
| PoolManager (Sepolia v4) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Sepolia callback proxy (Lasna) | `0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA` |
| Owner / admin / deployer | `0x193D1F3E085efc80e1027891FaA770E81ECC4A1d` |
| Buffer | 10,000 USDC real custody (re-seeded) |
| **Superseded** old hook | `0x50cd0E7e046022a9B359ca8725aCb75748FB67C0` / old PoolId `0xe531d420…f2b81cb` |

Pool stage/init/seed tx hashes (Sepolia, block 10998474): `0x5c8d5831…37bb9`,
`0xad9564b7…4da55d`, `0xf85b80de…07a7f0`, `0x667215cc…01a700`.

---

## 5. Deviation: hook redeploy (authorized by user)

The original task said *"do not redeploy the hook"* — premised on the callback proxy still being
`0x…fffFfF`. Research against `dev.reactive.network/origins-and-destinations` (cross-checked)
proved the Omni fork moved the Sepolia callback proxy to
`0xc9f36411…7bDA`. The live `0x50cd…` hook authorizes only `0x…fffFfF`, and its auth is
**immutable** (no setter). Direct-RPC checks confirmed the new system contract is at `0x8888…`
(matching the lib). **Conclusion:** the live hook could not receive Lasna callbacks; the user
chose to **redeploy** with the new proxy. Re-ran the Session-11 flow against the new proxy
(re-mine salt → new hook → new pool → re-seed buffer; MockUSDC reused).

---

## 6. Deviation: solc stayed 0.8.26 (lib pragma relaxed)

`reactive-lib-omni` is `pragma ^0.8.29`. Bumping the project to 0.8.30 was tried first but
**fails**: v4-core `PoolManager.sol` pins exact `0.8.26`, and the test contracts import both
`PoolManager` and the hook (which pulls the new lib) in one compilation unit — unsatisfiable at
any single version. Since the new lib uses **no 0.8.27+ features**, its 8 source files were
relaxed `^0.8.29` → `^0.8.26`. The project compiles on its original 0.8.26 toolchain (also
keeping source consistent with the deployed hook's bytecode compiler).

> **Reproducibility:** `reactive-lib-omni` is **vendored** — its `src/` is committed directly into
> `lib/` (NOT a git submodule, matching how `forge-std`/`v4-hooks-public` are tracked in this repo),
> so the `^0.8.26` pragma relaxation persists on a fresh `git clone` and `forge build`/`forge test`
> works with no submodule init and no manual sed. The re-apply one-liner only matters if you ever
> re-vendor from upstream. See `lib/reactive-lib-omni/VENDORED.md`.

---

## 7. End-to-end verification — results & gaps

**Verified (direct RPC reads on Lasna):**
- `RangeGuardReactive` has code (≈6.2 KB) at `0xC0e6…B70b`; immutables correct:
  `hookAddress = 0xFead…a7C0`, `hookChainId = 11155111`, `cronTopic = 0x04463f7c…b687` (Cron10),
  `minCheckpointInterval = 120`; rGas balance `0.05 lREACT`.
- `owner = 0x193D…C4A1d` (storage slot 0); `paused = 00` (active).
- **rGas economics:** with 0 tracked positions, the contract's balance is unchanged over ~8,200
  blocks — confirming rGas is charged **per dispatched callback**, not per `react()` execution.
- New hook + pool live on Sepolia; buffer seeded; the 4 stage/init/seed txs succeeded.

**Network note:** `lasna-omni-rpc.rnk.dev` and the pre-Omni `lasna-rpc.rnk.dev` both report
chainId `5318007` but are **separate ledgers** — the contract exists only on the `-omni` one.
Use the `-omni` RPC and `lasna-omni.reactscan.net` explorer.

**NOT done (Phase-7 steps 2–5):** LP deposit → `PositionTracked` → swap/heartbeat →
`Checkpointed` on Sepolia. This requires registering a position (an LP add) and a swap on the
live pool — there is **no LP-deposit/swap tooling** for the Sepolia pool yet (Session 11 only
seeded the buffer; `lpRouter`/`swapRouter` are unset for Sepolia). That tooling **is** the next
deliverable, `RangeGuardDemo.s.sol`.

---

## 8. Next steps

1. **`RangeGuardDemo.s.sol`** — add liquidity + swap on the live Sepolia pool to drive
   `PositionTracked` (ReactVM) → range/heartbeat callback → `Checkpointed` (Sepolia), completing
   the end-to-end proof.
2. Frontend dashboard (coverage report from Sepolia events).

**Operational reminders:** top up the reactive contract with `cast send 0xC0e6…B70b --value …`
(or `make reactive-topup`); `pause()`/`resume()` are owner-only on the Lasna RPC (`make
reactive-pause`/`reactive-resume`); the Callback Proxy is per-network (confirm for any new host
chain before deploying the hook).

---

## 9. Reproducibility — vendored deps + Makefile

**All dependencies are vendored (zero git submodules).** `forge-std`, `v4-hooks-public`, and now
`reactive-lib-omni` are committed directly under `lib/`. A fresh checkout therefore builds with no
submodule init and no manual steps:

```bash
git clone <repo> && cd RangeGuard
forge build && forge test     # 278 passing
```

`reactive-lib-omni` was de-submoduled this session specifically so its `^0.8.26` pragma relaxation
(see §6) ships in the commit rather than vanishing on `git submodule update` / `forge update`.
`lib/reactive-lib-omni/VENDORED.md` records the upstream version (`v0.1.0 @3ade0dc`), the pragma
edit, and the re-vendor procedure.

**The `Makefile` is now executable documentation of the deploy/ops flow.** Key targets (live
Session-12 addresses are overridable defaults; needs `PRIVATE_KEY` + `SEPOLIA_RPC_URL` in `.env`):

```
make build | test                          # dev
make deploy-hook-dry | deploy-hook         # hook → Sepolia
make mint-usdc | stage-init-seed           # buffer USDC + stage/init/seed pool
make faucet                                # lREACT on Lasna
make deploy-reactive-dry | deploy-reactive # reactive → Lasna
make reactive-balance | reactive-paused    # ops: rGas / pause state
make reactive-topup | reactive-pause | reactive-resume
```
