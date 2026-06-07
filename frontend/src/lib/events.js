// RangeGuardHook event + read ABIs, and the LimitingFactor enum.
//
// Every coverage-report row maps to one of these events (spec §4 / §10). All position-scoped
// events carry `positionKey` as the second indexed param (topic2), which is how rpc.js filters them.
import { parseAbi, decodeEventLog } from 'viem'

// Solidity: enum LimitingFactor { NONE, IL_CAP, COVERAGE_CAP, BUFFER_CAP }
export const LIMITING_FACTOR = ['NONE', 'IL_CAP', 'COVERAGE_CAP', 'BUFFER_CAP']

export const LIMITING_FACTOR_LABEL = {
  NONE: 'No cap (no IL)',
  IL_CAP: 'IL cap (50% of loss)',
  COVERAGE_CAP: 'Coverage cap (earned coverage)',
  BUFFER_CAP: 'Buffer cap (10% of buffer)',
}

// On the wire the enum is a uint8; declare it as such for decoding.
export const HOOK_ABI = parseAbi([
  // ---- events (coverage report) ----
  'event PositionRegistered(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed owner, int24 tickLower, int24 tickUpper, uint128 entryAmt0, uint128 entryAmt1, uint256 entryNotionalStable, int24 entryTick, uint32 depositTime, uint256 coverageApr, uint256 secondsPerYear)',
  'event AccrualUpdated(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 dt, uint256 delta, uint256 newEarnedTotal, bool isInRange, uint256 timestamp)',
  'event PositionOutOfRange(bytes32 indexed poolId, bytes32 indexed positionKey, int24 tickLower, int24 tickUpper, int24 currentTick, uint256 earnedCoverageStable, uint256 timestamp)',
  'event PositionBackInRange(bytes32 indexed poolId, bytes32 indexed positionKey, int24 tickLower, int24 tickUpper, int24 currentTick, uint256 earnedCoverageStable, uint256 timestamp)',
  'event Checkpointed(bytes32 indexed poolId, bytes32 indexed positionKey, uint256 timestamp)',
  'event ClaimSettled(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed owner, int24 tickLower, int24 tickUpper, uint256 ilRaw, uint256 earnedCoverage, uint256 payout, uint8 limitingFactor)',
  'event PartialPayout(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed owner, int24 tickLower, int24 tickUpper, uint256 requested, uint256 actual, uint8 limitingFactor)',
  'event NoClaim(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed owner, int24 tickLower, int24 tickUpper, uint256 vHodl, uint256 vActual)',
  'event IneligibleClaim(bytes32 indexed poolId, bytes32 indexed positionKey, address indexed owner, int24 tickLower, int24 tickUpper, bytes32 reason)',
  'event PositionClosed(bytes32 indexed poolId, bytes32 indexed positionKey, address owner)',
  // ---- public-mapping getters ----
  'function poolState(bytes32) view returns (uint256 bufferBalanceStable, uint256 totalSkimmedStable, uint256 totalPaidOutStable)',
  'function poolConfig(bytes32) view returns (uint24 baseLpFeeBps, uint24 bufferBps, uint256 coverageApr, uint256 secondsPerYear, uint32 minHoldSeconds, uint16 maxPayoutPctOfIl, uint16 maxPayoutPctOfBuffer, uint256 maxAccruedCoverageMultiple, uint256 targetBufferSize, uint32 minCheckpointInterval, address admin)',
  'function positions(bytes32, bytes32) view returns (uint128 entryAmt0, uint128 entryAmt1, int24 entryTick, int24 tickLower, int24 tickUpper, uint32 depositTime, uint32 lastAccrualTime, bool active, uint256 entryNotionalStable, uint256 earnedCoverageStable, uint128 liquidity)',
])

export const POOL_MANAGER_ABI = parseAbi(['function extsload(bytes32 slot) view returns (bytes32)'])

// Decode one raw log against the hook ABI. Returns null for anything that does not match
// (e.g. an event with this positionKey shape that we do not render).
export function decodeHookLog(log) {
  try {
    const { eventName, args } = decodeEventLog({
      abi: HOOK_ABI,
      data: log.data,
      topics: log.topics,
      strict: false,
    })
    return {
      eventName,
      args,
      txHash: log.transactionHash,
      blockNumber: BigInt(log.blockNumber),
      logIndex: Number(log.logIndex),
    }
  } catch {
    return null
  }
}
