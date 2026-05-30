# Spec Amendment: Pool Configuration — Two-Phase Staging + Deferred Reactive Registration

**Status:** Proposed — supersedes the `beforeInitialize`/`initializePoolConfig` flow in `spec.md` and the matching lifecycle steps in `state-machine.md`.
**Reason for amendment:** Two architectural changes documented per CLAUDE.md's rule against unannounced architectural changes:

1. v4-core `beforeInitialize` has no `hookData` — per-pool config cannot be passed through the callback.
2. Reactive contract address has a circular deployment dependency with the hook address — reactive registration is deferred to a post-initialization step.

---

## 1. Root cause

### 1a. No hookData on initialize callbacks

The current released v4-core `IHooks` interface provides no `hookData` to initialize callbacks:

```solidity
function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
```

`hookData` exists only on liquidity and swap callbacks. The original spec's flow — decode config from `hookData`, call internal `initializePoolConfig()` — is not implementable.

### 1b. Circular deployment dependency (reactive contract)

The reactive contract requires the hook address at deployment. The hook requires the reactive contract address to register access control. Neither can be known at the other's deploy time without CREATE2.

**MVP resolution:** defer reactive registration to a post-initialization step guarded by a one-time setter. Production deployments would use CREATE2 for fully atomic setup — worth noting in the hookathon submission as the intended production path.

### 1c. Open initializer attack surface

`PoolManager.initialize()` is a public function. An attacker knowing the poolKey could front-run initialization with a garbage `sqrtPriceX96`, distorting IL reference data. The hook validates both the caller (`sender`) and the price in `_beforeInitialize`.

---

## 2. Decision: three-phase pool setup

Pool bring-up is split across three phases:

**Phase 1 — Stage:** Owner stages config (without reactive address) and designates an authorized initializer and expected price. Pool does not exist yet.

**Phase 2 — Initialize:** Authorized initializer calls `PoolManager.initialize()`. Hook validates caller and price, commits config, marks pool initialized. Reactive address is not yet known.

**Phase 3 — Register reactive:** Owner deploys reactive contract (now has hook address), then calls `setReactiveContract()` once. A `_reactiveSet` guard ensures this can never be changed after being set — trustless after setup completes.

**Full deployment sequence:**

```
Step 1: Deploy hook contract
          → owner = msg.sender

Step 2: owner → hook.stagePoolConfig(key, config, authorizedInitializer, expectedSqrtPriceX96)
          → validates all bounds (no reactive address yet)
          → _pendingSetup[poolId] stored
          → emits PoolConfigStaged

Step 3: authorizedInitializer → PoolManager.initialize(key, expectedSqrtPriceX96)
          → hook._beforeInitialize(sender, key, sqrtPriceX96)
            → validates sender == authorizedInitializer
            → validates sqrtPriceX96 == expectedSqrtPriceX96
            → commits config, deletes pending setup, marks initialized
          → emits PoolConfigInitialized

Step 4: Deploy reactive contract (hook address now known)

Step 5: owner → hook.setReactiveContract(key, reactiveAddress)
          → validates pool initialized + not yet set + reactive != address(0)
          → reactiveContract[poolId] = reactiveAddress
          → _reactiveSet[poolId] = true  ← permanently locked after this
          → emits ReactiveContractSet

Step 6: admin → hook.seedBuffer(key, amount)
          → funds IL coverage pool
```

**Access control hierarchy:**

- `owner` (contract-level, immutable) — gates `stagePoolConfig` and `setReactiveContract`
- `authorizedInitializer` (per-pool, in pending setup) — the only address permitted to call `PoolManager.initialize()` for this pool
- `config.admin` (per-pool, in `PoolConfig`) — governs pool-level ops (e.g., `seedBuffer`)

---

## 3. Entry points

### `stagePoolConfig` (external, onlyOwner)

```solidity
function stagePoolConfig(
    PoolKey    calldata key,
    PoolConfig calldata config,
    address             authorizedInitializer,
    uint160             expectedSqrtPriceX96
) external onlyOwner;
```

Responsibilities:

- Revert `PoolAlreadyInitialized` if `_poolInitialized[poolId]` is true.
- Revert `ZeroAdmin` if `config.admin == address(0)`.
- Revert `ZeroInitializer` if `authorizedInitializer == address(0)`.
- Revert `ZeroSqrtPrice` if `expectedSqrtPriceX96 == 0`.
- Validate `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`); else `NotDynamicFee`.
- Validate all `PoolConfig` bounds including `config.maxPayoutPctOfBuffer <= BPS_DENOM`.
- Store `_pendingSetup[poolId]`.
- Emit `PoolConfigStaged(poolId, config, authorizedInitializer, expectedSqrtPriceX96)`.

Re-stageable before init — owner may overwrite at any time until `_poolInitialized[poolId]` is true.

### `_beforeInitialize` (callback, PoolManager-only)

```solidity
function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
    internal override returns (bytes4);
```

Responsibilities:

- Validate `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG`; else `NotDynamicFee`.
- Revert `PoolNotStaged` if `!_pendingSetup[poolId].exists`.
- Revert `UnauthorizedInitializer` if `sender != pendingSetup.authorizedInitializer`.
- Revert `UnexpectedSqrtPrice` if `sqrtPriceX96 != pendingSetup.expectedSqrtPriceX96`.
- Commit: `poolConfig[poolId] = pendingSetup.config`.
- Clean up: `delete _pendingSetup[poolId]`.
- Set `_poolInitialized[poolId] = true`.
- Emit `PoolConfigInitialized(poolId, config)`.
- Return `IHooks.beforeInitialize.selector`.

Note: `reactiveContract[poolId]` is NOT set here — it remains `address(0)` until `setReactiveContract` is called.

### `setReactiveContract` (external, onlyOwner)

```solidity
function setReactiveContract(PoolKey calldata key, address reactive) external onlyOwner;
```

Responsibilities:

- Revert `PoolNotInitialized` if `!_poolInitialized[poolId]`.
- Revert `ReactiveAlreadySet` if `_reactiveSet[poolId]` is true. ← permanent one-time guard
- Revert `ZeroReactive` if `reactive == address(0)`.
- Set `reactiveContract[poolId] = reactive`.
- Set `_reactiveSet[poolId] = true`.
- Emit `ReactiveContractSet(poolId, reactive)`.

Once `_reactiveSet[poolId]` is true, `reactiveContract[poolId]` is as immutable as any other config field. This is the only field in the config surface that is not set at initialization; all other `PoolConfig` fields are committed atomically in `_beforeInitialize`.

---

## 4. Responsibility re-mapping

| Original `beforeInitialize` responsibility             | New home                                                                          |
| ------------------------------------------------------ | --------------------------------------------------------------------------------- |
| Validate `DYNAMIC_FEE_FLAG`                            | `_beforeInitialize` (authoritative) + `stagePoolConfig` (fail-fast)               |
| Decode `PoolConfig`/`reactiveContract` from `hookData` | **Removed** — typed args split across `stagePoolConfig` and `setReactiveContract` |
| Validate `PoolConfig` bounds                           | `stagePoolConfig`                                                                 |
| Initialize config atomically                           | Commit in `_beforeInitialize`                                                     |
| Register `reactiveContract`                            | `setReactiveContract` (deferred, post-deploy)                                     |
| Mark pool initialized                                  | `_beforeInitialize` (`_poolInitialized`)                                          |
| Prevent partially-initialized pools                    | `PoolNotStaged` + sender/price checks in `_beforeInitialize`                      |
| Emit `PoolConfigInitialized`                           | `_beforeInitialize`                                                               |

`initializePoolConfig()` internal-only — **removed**.

---

## 5. State, errors, events

**New struct**

```solidity
struct PendingPoolSetup {
    PoolConfig config;
    address    authorizedInitializer;
    uint160    expectedSqrtPriceX96;
    bool       exists;
}
```

**State**

```solidity
address public immutable owner;

mapping(PoolId => PendingPoolSetup) private _pendingSetup;
mapping(PoolId => PoolConfig)       public  poolConfig;
mapping(PoolId => address)          public  reactiveContract;
mapping(PoolId => bool)             private _poolInitialized;
mapping(PoolId => bool)             private _reactiveSet;
```

**Errors**
`PoolAlreadyInitialized`, `PoolNotInitialized`, `PoolNotStaged`, `NotOwner`, `ZeroAdmin`, `ZeroReactive`, `ZeroInitializer`, `ZeroSqrtPrice`, `UnauthorizedInitializer`, `UnexpectedSqrtPrice`, `ReactiveAlreadySet`, `NotDynamicFee`, `InvalidFeeConfig`, `InvalidApr`, `InvalidPayoutCaps`, `UnsupportedDayCount`.

**Events**

- `PoolConfigStaged(PoolId indexed poolId, PoolConfig config, address authorizedInitializer, uint160 expectedSqrtPriceX96)`
- `PoolConfigInitialized(PoolId indexed poolId, PoolConfig config)`
- `ReactiveContractSet(PoolId indexed poolId, address reactive)`

---

## 6. Invariants

- `_poolInitialized[id] ⟹ poolConfig[id].admin != address(0)` — config committed at init.
- `_poolInitialized[id] ⟹ !_pendingSetup[id].exists` — pending setup cleaned up on commit.
- `_poolInitialized[id] ⟹ poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM` — on-chain enforced at stage time.
- `_reactiveSet[id] ⟹ reactiveContract[id] != address(0)` — reactive registration is non-zero once set.
- `_reactiveSet[id] ⟹ _poolInitialized[id]` — reactive can only be set after init.
- `_reactiveSet[id]` is permanently true once set — `ReactiveAlreadySet` prevents any change.

**Note on downstream callbacks:** any callback that calls into `reactiveContract[id]` should guard on `_reactiveSet[id]` and handle the not-yet-set window (Steps 3→5) gracefully. This is enforced in those callbacks, not here.

---

## 7. Resolved design decisions

| #   | Question                     | Resolution                                                                                                                           |
| --- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Reactive zero-policy         | Reject `address(0)` → `ZeroReactive` (in `setReactiveContract`)                                                                      |
| 2   | Admin zero-policy            | Reject `address(0)` → `ZeroAdmin` (in `stagePoolConfig`)                                                                             |
| 3   | Re-stage before init         | Allowed — owner overwrites `_pendingSetup[poolId]`                                                                                   |
| 4   | Access control on staging    | `onlyOwner`                                                                                                                          |
| 5   | Initializer authorization    | Per-pool `authorizedInitializer`; checked via `sender` in `_beforeInitialize`                                                        |
| 6   | Price integrity              | Exact `expectedSqrtPriceX96` match; MVP — no tolerance window                                                                        |
| 7   | Reactive circular dependency | Deferred to `setReactiveContract` post-deploy; `_reactiveSet` guard ensures one-time set. Production: CREATE2 for atomic deployment. |

---

## 8. Security analysis

- Attacker cannot initialize before staging → `PoolNotStaged`.
- Attacker cannot stage → `onlyOwner`.
- Attacker cannot initialize with wrong price → `UnexpectedSqrtPrice`.
- Attacker cannot initialize as wrong address → `UnauthorizedInitializer`.
- Attacker cannot change reactive after set → `ReactiveAlreadySet`.
- Owner error recovery: re-stage before init to correct any parameter.
- If `_beforeInitialize` reverts for any reason → `PoolManager.initialize()` reverts entirely; pool never created.
- Live-but-incomplete window (Steps 3→5): pool is initialized but `_reactiveSet` is false. Owner should complete Steps 4–5 before opening pool to LPs. Downstream callbacks guard on `_reactiveSet`.

---

## 9. Test plan (unit → fuzz → invariant)

### `stagePoolConfig`

- Reverts: not owner, pool already initialized, zero admin, zero initializer, zero sqrtPrice, non-dynamic-fee key, each invalid bound.
- Success: `_pendingSetup[poolId]` populated, `PoolConfigStaged` emitted.
- Re-stage: owner overwrites; new values stored.
- Fuzz: valid inputs round-trip; invalid inputs revert.

### `_beforeInitialize`

- Reverts: non-PoolManager caller, non-dynamic-fee key, no pending setup, wrong sender, wrong sqrtPrice.
- Success: `poolConfig[id]` set, `_pendingSetup[id]` deleted, `_poolInitialized[id]` true, `PoolConfigInitialized` emitted, correct selector returned.
- Verify `reactiveContract[id] == address(0)` after init (not yet set).

### `setReactiveContract`

- Reverts: not owner, pool not initialized, reactive already set, zero reactive address.
- Success: `reactiveContract[id]` set, `_reactiveSet[id]` true, `ReactiveContractSet` emitted.
- Second call reverts `ReactiveAlreadySet` regardless of caller.

### Invariant

- `_poolInitialized[id] ⟹ poolConfig[id].admin != address(0)`.
- `_poolInitialized[id] ⟹ !_pendingSetup[id].exists`.
- `_poolInitialized[id] ⟹ poolConfig[id].maxPayoutPctOfBuffer <= BPS_DENOM`.
- `_reactiveSet[id] ⟹ reactiveContract[id] != address(0)`.
- `_reactiveSet[id] ⟹ _poolInitialized[id]`.

---

## 10. Documents to that were updated (Claude Code Step 0)

| File                   | What to change                                                                                                                                                                                                                                                                           |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spec.md`              | Replace `beforeInitialize` + `initializePoolConfig` with three-phase setup (§2–§3). Remove hookData-for-init. Remove "initializePoolConfig() is internal-only". Add `PendingPoolSetup`, `setReactiveContract`, `_reactiveSet`, and deployment sequence. Note CREATE2 as production path. |
| `state-machine.md`     | Pool lifecycle: UNREGISTERED → STAGED → INITIALIZED → REACTIVE_SET → SEEDED. Add transitions for each step.                                                                                                                                                                              |
| `invariant-mapping.md` | Add all invariants from §6. Update `maxPayoutPctOfBuffer` enforcement site to `stagePoolConfig`. Note `_reactiveSet` guard as the immutability mechanism for reactive address.                                                                                                           |
| `testing-strategy.md`  | Add `stagePoolConfig`, `_beforeInitialize` (commit), and `setReactiveContract` test blocks (§9).                                                                                                                                                                                         |
| `project-status.md`    | Note Phase 2 design amended; reference this document.                                                                                                                                                                                                                                    |
