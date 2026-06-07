```
============================================================
   RangeGuard - IL Coverage Demo (Sepolia Fork)
   "Protect your liquidity. Guard your range."
============================================================
[Pool Configuration]
  Hook:                  0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0
  baseLpFeeBps:          3000 (0.30%)
  bufferBps:             1000 (0.10%)
  totalFee:              4000 (0.40%)
  coverageApr (1e18):    500000000000000000 (50%)
  minHoldSeconds:        300
  minCheckpointInterval: 120
------------------------------------------------------------
[Setup] Pool live + seeded on Sepolia fork
  Buffer balance: 10000.80 USDC (10% of target)
------------------------------------------------------------
[Day 0] LP deposits a mix of ETH + USDC (Case B - price in range)
  Entry notional: 228.38 USDC  |  Range: [$1,800, $2,200]
  PositionRegistered ok
------------------------------------------------------------
[Day 3] Swap: ETH -> USDC (in range)
  BufferFunded +0.01 USDC  |  buffer: 10000.82 USDC
[Day 7] Swap: USDC -> ETH (in range)
  BufferFunded +0.02 USDC  |  buffer: 10000.84 USDC
[Day 12] Swap: ETH -> USDC (in range)
  BufferFunded +0.01 USDC  |  buffer: 10000.86 USDC
[Day 15] Checkpoint
  AccrualUpdated: +4.69 USDC (isInRange: true)  |  total coverage: 4.69 USDC
[Day 18] Large swap: ETH -> USDC crosses tickLower DOWN
  Position is now OUT OF RANGE (tick -204721 < tickLower)
  [Reactive Network] checkpointAndEmitOutOfRange fires on live Sepolia (simulated here)
  BufferFunded +0.14 USDC (buffer grows regardless of range)
[Day 20] Checkpoint
  AccrualUpdated: +0.00 USDC (isInRange: false)  |  total coverage: 4.69 USDC
[Day 22] Large swap: USDC -> ETH crosses tickLower UP
  Position is BACK IN RANGE (tick -200438)
  [Reactive Network] checkpointAndEmitBackInRange fires on live Sepolia (simulated here)
  BufferFunded +0.15 USDC | accrual resumes
[Day 30] Swap: ETH -> USDC (in range, price drifts toward $1,850)
  BufferFunded +0.11 USDC  |  buffer: 10001.26 USDC
[Day 38] Swap: ETH -> USDC (in range)
  BufferFunded +0.03 USDC  |  buffer: 10001.30 USDC
[Day 43] Swap: USDC -> ETH (nudge back in range)
  BufferFunded +0.03 USDC | tick back in range
[Day 45] Checkpoint
  AccrualUpdated: +7.82 USDC (isInRange: true)  |  total coverage: 12.51 USDC
------------------------------------------------------------
[Day 45] LP withdraws the full position
  IL_raw: 4.47 USDC  |  Payout: 2.23 USDC
  Limiting Factor: IL_CAP  |  ClaimSettled ok
------------------------------------------------------------
[Final Summary]
  Fees skimmed:    1.34 USDC
  Paid out:        2.25 USDC
  Buffer balance:  9999.09 USDC (9% of target)
  Buffer retained 99% of the 10,000 USDC seed - coverage is self-funding.
============================================================
```
