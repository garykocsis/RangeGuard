# Purpose

This document defines the core protocol invariants for RangeGuard.

Invariants are conditions that must always remain true regardless of:

- swaps
- checkpoints
- liquidity events
- range transitions
- Reactive Network interactions
- execution ordering
- fuzzed inputs

These invariants serve as the canonical safety and correctness rules for:

- protocol implementation
- invariant testing
- fuzz testing
- integration testing
- audit review
- AI-assisted development

All accounting, accrual, settlement, and lifecycle logic should preserve these invariants under all valid execution paths.

# Accounting Invariants

- earnedCoverageStable must never decrease
- earnedCoverageStable must never exceed the configured accrual ceiling
- inactive positions must never accrue coverage
- pendingPayout must never be negative
- bufferBalanceStable must never be negative
- accrual must never modify entry position snapshots
- lastAccrualTime must monotonically increase
- checkpoint() must never reduce total earned coverage

# Range & Accrual Invariants

- coverage must only accrue while a position is in range
- out-of-range checkpoints must produce zero accrual delta
- zero dt must produce zero accrual delta
- accrual must always use the current derived range status
- accrual eligibility must be derived from:
  - active position
  - in-range status
  - dt > 0
- checkpoint() must never bypass range gating
- afterSwap must never directly accrue positions
- accrual calculations must never iterate over all LP positions
- earnedCoverageStable must remain unchanged while out of range

# Settlement Invariants

- IL_raw must never be negative
- payout must never exceed IL_covered
- payout must never exceed earnedCoverageStable
- payout must never exceed bufferCap
- payout must never exceed bufferBalanceStable
- payout must never exceed the configured payout caps
- positions failing minHoldSeconds eligibility must always receive zero payout
- settlement must never modify immutable entry snapshots
- pendingPayout must be cleared after settlement
- cleared positions must never retain payout state

# Authorization Invariants

- onlyReactive(poolId) may emit range transition events
- Reactive contracts must never directly mutate accounting state
- only pool admin may call seedBuffer()
- PoolConfig parameters must remain immutable after initialization
- initializePoolConfig() must only succeed once per pool
- dynamicFeeBps must always be derived and never independently stored
- unauthorized actors must never trigger payout execution
- unauthorized actors must never mutate position settlement state
- unauthorized actors must never mutate buffer accounting state

# Initialization Invariants

- pools must initialize with DYNAMIC_FEE_FLAG enabled
- initialized pools must always have valid immutable PoolConfig
- partially initialized pools must never exist
- PoolConfig initialization must occur exactly once per pool
- reactiveContract registration must occur during initialization

# Lifecycle Invariants

- inactive positions must never accrue coverage
- inactive positions must never checkpoint
- inactive positions must never settle
- cleared positions must never retain payout state
- cleared positions must never retain active status
- pending settlements must never continue accruing coverage
- settlement must always finalize before cleanup
- active positions must always have valid entry snapshots
- active positions must always have initialized accrual state
- positions must never transition directly from Cleared to active

# Timing Invariants

- lastAccrualTime must monotonically increase
- dt must never underflow
- zero dt must always produce zero accrual delta
- checkpoint() must enforce minCheckpointInterval
- accrual calculations must always use block.timestamp as the current time reference
- settlement accrual must always occur before payout computation
- minHoldSeconds eligibility must always be evaluated before payout computation
- accrual calculations must never use stale range status
- checkpoints must never create overlapping accrual periods
