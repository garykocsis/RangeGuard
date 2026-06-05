# Session 11 — Sepolia Deployment (Hook live + pool seeded)

Date: 2026-06-05
Branch: `feat/sepolia-deployment`
Target: First live Ethereum Sepolia deployment — MockUSDC → hook → pool staged → pool
initialized → buffer seeded, fully verified on-chain.

Status: ✅ COMPLETE. Hook deployed, ETH/USDC pool initialized with DYNAMIC_FEE_FLAG, buffer
seeded with 10,000 USDC of real custody. No production contract source changed (only a new
testnet mock + deploy scripts + docs).

---

## Deployed addresses (Ethereum Sepolia, chainId 11155111)

| Item | Address |
| --- | --- |
| RangeGuardHook | `0x50cd0E7e046022a9B359ca8725aCb75748FB67C0` (✅ Etherscan-verified) |
| MockUSDC (token1, 6 dec) | `0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA` (✅ Etherscan-verified) |
| PoolManager (Uniswap v4) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Callback Proxy (`_callbackSender`) | `0x0000000000000000000000000000000000fffFfF` |
| Owner / admin / authorizedInitializer / signer | `0x193D1F3E085efc80e1027891FaA770E81ECC4A1d` |

## Pool

| Field | Value |
| --- | --- |
| PoolId | `0xe531d42027094e6563d0838d0fe1c8705172d4feed0e6a5f48a08ca97f2b81cb` |
| currency0 (token0 = ETH, 18 dec) | `0x0000000000000000000000000000000000000000` (native) |
| currency1 (token1 = USDC, 6 dec) | `0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA` |
| fee | `0x800000` (DYNAMIC_FEE_FLAG) |
| tickSpacing | 60 |
| sqrtPriceX96 ($2,000/ETH) | `3543191142285914205922034` (tick ≈ −200312) |

### sqrtPriceX96 derivation
token0 = ETH (18 dec), token1 = USDC (6 dec). `sqrtPriceX96 = isqrt(amount1 · 2^192 / amount0)`
with `amount1 = 2000·1e6`, `amount0 = 1e18` → `3543191142285914205922034`. The SAME constant
feeds both `stagePoolConfig.expectedSqrtPriceX96` and `PoolManager.initialize` (a single
`SQRT_PRICE_X96` constant in `StageInitSeedPool.s.sol`), so the `UnexpectedSqrtPrice` guard
cannot trip.

## Committed PoolConfig (verified via `poolConfig(poolId)`)

| Field | Value |
| --- | --- |
| baseLpFeeBps | 3000 (0.30%) |
| bufferBps | 1000 (0.10%) |
| coverageApr | 0.5e18 (50%) |
| secondsPerYear | 31_536_000 (A/365F) |
| minHoldSeconds | 300 (5 min) |
| maxPayoutPctOfIl | 5000 (50%) |
| maxPayoutPctOfBuffer | 1000 (10%) |
| maxAccruedCoverageMultiple | 3e18 (3x) |
| targetBufferSize | 100_000e6 |
| minCheckpointInterval | 120 (2 min) |
| admin | `0x193D1F3E085efc80e1027891FaA770E81ECC4A1d` |

## Buffer (verified via `poolState(poolId)` + ERC20 balance)
- `bufferBalanceStable` = 10_000e6, `totalSkimmedStable` = 0, `totalPaidOutStable` = 0
  (seed credits the balance only; fee accounting untouched — per `seedBuffer` spec).
- Hook real USDC custody = 10_000e6; deployer USDC = 0 (fully moved into the buffer).
- `BufferSeeded` event emitted (topic0 `0x3881b70a1f461b2cadee3aa124f1519a18b596faa45b865889a2da6791eea07d`).

---

## Transaction hashes

| Step | Tx |
| --- | --- |
| MockUSDC deploy (CREATE) | `0xc0a63500040fca1dac5e419aa42b19912f96c60e71f2666c1ceb5197569559fb` |
| MockUSDC mint 10_000e6 → deployer | `0x2c6d6f93db67ce23df699b9e84f3d417716a86913dc0c84ecd4cf57978b7ab68` |
| Hook deploy (CREATE2) | `0x4fd838f06a7c7e2eef429bce57a6d595c18df16c57f5f16c6f799f146765a058` |
| stagePoolConfig | `0x78d440d31565cd7d1f18723caa0a661539587f33a18ebe1f134ae980c238a695` |
| PoolManager.initialize | `0x92064076492f48463c4f76afabb1011709e672d7e44ec2e6a67084d50e666fc5` |
| approve(hook, 10_000e6) | `0x584b6f1899c8aa55501ea9feee56f73e6116aa472cf8e0c73a458c998ccbdead` |
| seedBuffer | `0x115f95b4b7fbffa3e32eb92c4727b33fe1f655a23482c330a18fcdb92cae89e1` |

## Etherscan verification
Both contracts verified on Sepolia Etherscan (confirmed via API `getabi`):
- RangeGuardHook — https://sepolia.etherscan.io/address/0x50cd0e7e046022a9b359ca8725acb75748fb67c0#code
  (constructor args: PoolManager `0xE03A1074…203543`, owner `0x193D1F3E…4A1d`, callbackSender `0x…fffFfF`)
- MockUSDC — https://sepolia.etherscan.io/address/0x04fecef5110c5e52794fda3d935bc2cc0ee428ca#code

Hook flag sanity: hook address low 14 bits = `0x27c0` = exactly
`BEFORE_INITIALIZE | AFTER_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY |
BEFORE_SWAP | AFTER_SWAP` (no extras).

---

## Artifacts added this session

- `src/mocks/MockUSDC.sol` — testnet-only 6-dec ERC20, permissionless `mint` (TESTNET ONLY).
- `script/DeployMockUSDC.s.sol` — deploy MockUSDC + mint 10_000e6 to the seedBuffer signer.
- `script/StageInitSeedPool.s.sol` — stage → initialize → approve → seedBuffer in one broadcast;
  PoolKey built once and reused in-memory; single `SQRT_PRICE_X96` constant.
- `script/helpers/HelperConfig.s.sol` — added `MOCK_USDC_SEPOLIA` (persisted) + `getStableToken()`
  (reads `MOCK_USDC_ADDRESS` env override, falls back to the constant). token1's single read point.

## Enforced constraints
1. **Mint recipient = seedBuffer signer.** `seedBuffer` does `transferFrom(msg.sender, …)`; the
   mint recipient, `config.admin`, and the broadcasting key are one address (the deployer).
2. **approve before seedBuffer.** The script approves inline immediately before seeding; the
   explicit cast equivalent is in the runbook below. Never assumed from a test harness.
3. **Persist `MOCK_USDC_SEPOLIA` immediately.** Set in HelperConfig in this session right after
   the MockUSDC broadcast — never left at `address(0)`.

---

## Test + coverage (post-deployment, 2026-06-05)

`forge test`: **278 passed, 0 failed, 0 skipped** (50 suites, 45.6s wall / 235.9s CPU). Invariant
campaigns ran at full strength — 50,000 calls × 0 reverts on every handler (checkpoint, settlement,
buffer-funding, range-event, accrue, etc.).

`forge coverage --report summary` (production contracts ~fully covered; deployment-only artifacts
are validated by the live Sepolia broadcast, not the unit suite):

| Contract | % Lines | % Statements | % Branches | % Funcs |
| --- | --- | --- | --- | --- |
| src/RangeGuardHook.sol | 100.00% (244/244) | 99.68% (312/313) | 98.00% (49/50) | 100.00% (29/29) |
| src/RangeGuardReactive.sol | 100.00% (81/81) | 98.86% (87/88) | 100.00% (12/12) | 100.00% (9/9) |
| script/helpers/HelperConfig.s.sol | 60.71% (17/28) | 64.29% (18/28) | 33.33% (2/6) | 40.00% (2/5) |
| script/DeployRangeGuardHook.s.sol | 100.00% (23/23) | 100.00% (32/32) | 66.67% (2/3) | 100.00% (1/1) |
| script/DeployMockUSDC.s.sol | 0.00% (0/13) | 0.00% (0/14) | n/a | 0.00% (0/1) |
| script/StageInitSeedPool.s.sol | 0.00% (0/26) | 0.00% (0/32) | 0.00% (0/4) | 0.00% (0/1) |
| script/DeployRangeGuardReactive.s.sol | 0.00% (0/18) | 0.00% (0/23) | n/a | 0.00% (0/1) |
| src/mocks/MockUSDC.sol | 0.00% (0/4) | 0.00% (0/2) | n/a | 0.00% (0/2) |
| **Total** | **90.50% (848/937)** | **90.64% (910/1004)** | **87.78% (79/90)** | **88.81% (119/134)** |

Notes:
- The two protocol contracts (`RangeGuardHook`, `RangeGuardReactive`) are at 100% line/function
  coverage; only 1 hook statement / 1 hook branch and 1 reactive statement remain uncovered (all
  pre-existing — none touched this session).
- The ~90% total is dragged down by deployment-only code (`DeployMockUSDC.s.sol`,
  `StageInitSeedPool.s.sol`, `MockUSDC.sol`, HelperConfig's chain branches) which is exercised by
  the live Sepolia broadcast above rather than by `forge test`. No protocol regression.

---

## Runbook (reproducible)

```bash
set -a && . ./.env && set +a   # PRIVATE_KEY, SEPOLIA_RPC_URL

# 1. MockUSDC (deploy + mint 10_000e6 to signer)
forge script script/DeployMockUSDC.s.sol:DeployMockUSDC \
  --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --broadcast
# -> persist printed address into HelperConfig.MOCK_USDC_SEPOLIA, then:
export MOCK_USDC_ADDRESS=0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA

# 2. Hook (CREATE2 + HookMiner; owner = signer)
forge script script/DeployRangeGuardHook.s.sol:DeployRangeGuardHook \
  --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --broadcast
export HOOK_ADDRESS=0x50cd0E7e046022a9B359ca8725aCb75748FB67C0

# 3. Stage + initialize + approve + seed (one broadcast)
forge script script/StageInitSeedPool.s.sol:StageInitSeedPool \
  --rpc-url $SEPOLIA_RPC_URL --chain-id 11155111 --broadcast

# (Explicit approve equivalent — already executed inline by step 3; never skip it manually:)
# cast send $MOCK_USDC_ADDRESS "approve(address,uint256)" $HOOK_ADDRESS 10000000000 \
#   --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

Each script was dry-run against the live Sepolia fork (no `--broadcast`) and confirmed clean
before broadcasting.

---

## Carry-ins / next steps
- Reactive contract NOT yet deployed to ReactVM this session (hook side is live + ready;
  `DeployRangeGuardReactive.s.sol` exists). Before deploying Reactive: confirm Cron topic, rGas
  funding amount, and the Callback Proxy on the target network (reactiveSpec §18.3/§18.7/§18.9).
- Next: demo script (`RangeGuardDemo.s.sol`, 45-day vm.warp lifecycle) run against this live pool
  to populate event history; then the frontend dashboard.
- `mint` on MockUSDC is permissionless — mint more USDC anytime for LP deposits in the demo.
- Payout recipient = v4 sender (owner=sender MVP) — unchanged.
