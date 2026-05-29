# RangeGuard

> Protect your liquidity. Guard your range.

A Uniswap v4 hook providing native, on-chain impermanent loss coverage
for liquidity providers. Coverage accrues over time via a day-count
convention, is funded by dynamic fee skimming, and pays out automatically
on full withdrawal.

## Overview

- Coverage accrues only while LP position is in range
- Funded by a portion of swap fees via v4 dynamic fees
- Automatic settlement on full withdrawal
- Three-cap payout system (IL cap, coverage cap, buffer cap)
- Full coverage report generated from on-chain events

## Architecture

- Single hook contract supporting multiple pools
- Lazy accrual model (no O(N) iteration on swaps)
- Reactive Network integration for range monitoring and checkpoints
- Immutable PoolConfig per pool

## Project Status

See project-status.md for current implementation progress.

## Documentation

- spec.md — full technical specification
- context.md — architecture context and design decisions
- state-machine.md — LP position lifecycle
- invariant-mapping.md — protocol invariants
- testing-strategy.md — test philosophy and coverage goals

## Development

Built with Foundry.

\```bash

# Build

forge build

# Test

forge test

# Test with verbosity

forge test -vvv
\```

## Target

Uniswap v4 Hook Incubator — Testnet MVP (ETH/USDC demo pool)
