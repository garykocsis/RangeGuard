# RangeGuard Project Status

Last Updated: 2026-05-28

## Current Phase

Current Task:

- Implement \_accrue()

Status:

- Design Review Complete
- Implementation Not Started

---

# Core Protocol Development

## \_accrue()

Status: IN PROGRESS

### Design

- [x] Architecture review
- [x] Storage review
- [x] Edge cases identified
- [x] Invariants identified

### Implementation

- [ ] Implement \_accrue()

### Unit Tests

- [ ] Create test suite
- [ ] dt = 0
- [ ] in range accrual
- [ ] out of range accrual
- [ ] boundary tick behavior

### Fuzz Tests

- [ ] coverage monotonic
- [ ] larger notional => larger accrual
- [ ] out of range => zero accrual

### Invariant Tests

- [ ] accrued coverage never decreases
- [ ] timestamp monotonic
- [ ] entry snapshots immutable

---

## \_computeIL()

Status: NOT STARTED

### Design

- [ ] Architecture review

### Implementation

- [ ] Implement \_computeIL()

### Testing

- [ ] Unit tests
- [ ] Fuzz tests
- [ ] Invariant tests

---

## \_computePayout()

Status: NOT STARTED

### Design

- [ ] Architecture review

### Implementation

- [ ] Implement \_computePayout()

### Testing

- [ ] Unit tests
- [ ] Fuzz tests
- [ ] Invariant tests

---

# Hook Callbacks

## beforeInitialize()

Status: PARTIAL

## afterAddLiquidity()

Status: PARTIAL

## beforeSwap()

Status: PARTIAL

## afterSwap()

Status: PARTIAL

## beforeRemoveLiquidity()

Status: PARTIAL

## afterRemoveLiquidity()

Status: PARTIAL

---

# Testing Infrastructure

## Deployment Framework

Status: COMPLETE

- [x] DeployRangeGuardHook.s.sol
- [x] HelperConfig.s.sol

## Shared Test Harness

Status: COMPLETE

- [x] BaseRangeGuardTest

---

# Recently Completed

- Hook scaffold created
- getHookPermissions() implemented in test/unit/RangeGuardTest.t
- Deployment scripts created
- BaseRangeGuardTest created
- PoolConfig initialization moved to beforeInitialize()
- DYNAMIC_FEE_FLAG enforcement added
- Documentation system established

---

# Next Actions

1. Implement \_accrue()
2. Write \_accrue() unit tests
3. Write \_accrue() fuzz tests
4. Write \_accrue() invariant tests
5. Begin \_computeIL()

# Development Roadmap

## Phase 1: Core Accounting Primitives

- [ ] \_accrue()
- [ ] \_accrue() unit tests
- [ ] \_accrue() fuzz tests
- [ ] \_accrue() invariant tests

- [ ] \_computeIL()
- [ ] \_computeIL() unit tests
- [ ] \_computeIL() fuzz tests
- [ ] \_computeIL() invariant tests

- [ ] \_computePayout()
- [ ] \_computePayout() unit tests
- [ ] \_computePayout() fuzz tests
- [ ] \_computePayout() invariant tests

## Phase 2: Hook Callback Implementation

- [ ] beforeInitialize()
- [ ] beforeInitialize() tests

- [ ] afterAddLiquidity()
- [ ] afterAddLiquidity() tests

- [ ] beforeSwap()
- [ ] beforeSwap() tests

- [ ] afterSwap()
- [ ] afterSwap() tests

- [ ] beforeRemoveLiquidity()
- [ ] beforeRemoveLiquidity() tests

- [ ] afterRemoveLiquidity()
- [ ] afterRemoveLiquidity() tests

## Phase 3: Integration Testing

- [ ] Full LP lifecycle
- [ ] Coverage accrual lifecycle
- [ ] Buffer funding lifecycle
- [ ] Settlement lifecycle

## Phase 4: Protocol Invariants

- [ ] Accounting invariants
- [ ] Lifecycle invariants
- [ ] Settlement invariants
- [ ] Authorization invariants

## Phase 5: Deployment Readiness on Anvil

- [ ] Anvil deployment
- [ ] Security review

## Phase 6: Deployment Readiness on Sepolia

- [ ] Sepolia deployment
- [ ] Security review
- [ ] Mainnet readiness review
