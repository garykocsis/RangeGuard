# Purpose

This document defines the valid lifecycle states and transitions
for RangeGuard LP positions.

It serves as the canonical reference for:

- hook behavior
- Reactive Network interactions
- testing logic
- invariant generation
- frontend state interpretation

# Position Lifecycle State Machine

## Core Position States

### Registered

Position exists and is active.

Properties:

- active == true
- pendingPayout == 0
- position registered in storage

### InRangeAccruing

Position is active and current tick is inside range.

Properties:

- accrual enabled
- checkpoint() may increase earnedCoverageStable

### OutOfRangePaused

Position is active but current tick is outside range.

Properties:

- accrual paused
- checkpoint() emits zero accrual delta

### PendingSettlement

Position withdrawal initiated.

Properties:

- pendingPayout computed
- final accrual completed
- payout awaiting execution
- no further accrual permitted

### Settled

Payout execution completed.

Properties:

- ClaimSettled / NoClaim emitted
- buffer updated
- payout finalized

### Cleared

Position storage reset.

- storage slot available for reuse

Properties:

- active == false
- pendingPayout == 0
- position no longer valid

# Valid State Transitions

afterAddLiquidity:

- -> Registered

checkpoint() while in range:

- Registered -> InRangeAccruing
- InRangeAccruing -> InRangeAccruing

checkpoint() while out of range:

- InRangeAccruing -> OutOfRangePaused
- OutOfRangePaused -> OutOfRangePaused

Reactive range re-entry:

- OutOfRangePaused -> InRangeAccruing

beforeRemoveLiquidity:

- any active state -> PendingSettlement

afterRemoveLiquidity:

- PendingSettlement -> Settled

cleanup:

- Settled -> Cleared

# Invalid Transitions

The following transitions are invalid:

- Cleared -> Active
- PendingSettlement -> InRangeAccruing
- Settled -> PendingSettlement
- inactive position -> checkpoint()
- inactive position -> payout execution

# State Ownership Rules

Hook contract owns:

- accounting state
- payout state
- accrual state

Reactive contract owns:

- external automation
- tick monitoring
- heartbeat scheduling

Reactive contract must never directly mutate accounting state.

# Derived State Rules

Range status is derived from:
tickLower <= currentTick < tickUpper

Accrual eligibility is derived from:

- active position
- in-range status
- dt > 0

Claim eligibility is derived from:
block.timestamp - depositTime >= minHoldSeconds

# Frontend Interpretation Rules

Coverage reports should interpret:

- InRangeAccruing as "earning coverage"
- OutOfRangePaused as "coverage paused"
- PendingSettlement as "claim processing"
- Cleared as "position closed"
