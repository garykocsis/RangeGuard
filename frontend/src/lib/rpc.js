// Viem client setup + on-chain read helpers for the live RangeGuard deployment on Sepolia.
//
// No backend, no API keys — everything is read from public Sepolia RPC endpoints.
import { createPublicClient, fallback, http, keccak256, encodeAbiParameters } from 'viem'
import { sepolia } from 'viem/chains'
import { HOOK_ABI, POOL_MANAGER_ABI } from './events.js'

/* //////////////////////////////////////////////////////////////
                       LIVE DEPLOYMENT (Sepolia)
////////////////////////////////////////////////////////////// */

export const ADDRESSES = {
  hook: '0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0',
  poolManager: '0xE03A1074c86CFeDd5C142C4F04F1a1536e203543',
  mockUsdc: '0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA',
  demoLpRouter: '0xEA30a770E6B3C3d30074908Af13b930d6d451FEa',
  callbackProxy: '0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA',
  reactive: '0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1', // Reactive Lasna
  deployer: '0x193D1F3E085efc80e1027891FaA770E81ECC4A1d',
}

export const POOL_ID = '0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a'

// Canonical demo position used by the recorded walkthrough. Overridable via ?positionKey=.
export const DEMO_POSITION_KEY = '0x62e2311b3a51692f0f8ce68f4cd03882e163b37aa357431ad14a4f5b41462d88'

// The hook was deployed in Session 12; its earliest events are ~block 11,005,575.
// Floor the log scan here so getLogs never sweeps the whole chain.
export const DEPLOY_BLOCK = 11005000n

// Explorers
export const ETHERSCAN = 'https://sepolia.etherscan.io'
export const REACTSCAN = 'https://lasna-omni.reactscan.net'

// Public Sepolia RPCs (fallback in order). publicnode verified working for eth_getLogs + extsload.
const RPC_URLS = [
  'https://ethereum-sepolia-rpc.publicnode.com',
  'https://1rpc.io/sepolia',
  'https://rpc.sepolia.org',
]

export const client = createPublicClient({
  chain: sepolia,
  transport: fallback(RPC_URLS.map((u) => http(u, { timeout: 15_000 })), { rank: false }),
})

/* //////////////////////////////////////////////////////////////
                           READ HELPERS
////////////////////////////////////////////////////////////// */

// poolState(poolId) -> { bufferBalanceStable, totalSkimmedStable, totalPaidOutStable } (all 1e6)
export async function readPoolState() {
  const [bufferBalanceStable, totalSkimmedStable, totalPaidOutStable] = await client.readContract({
    address: ADDRESSES.hook,
    abi: HOOK_ABI,
    functionName: 'poolState',
    args: [POOL_ID],
  })
  return { bufferBalanceStable, totalSkimmedStable, totalPaidOutStable }
}

// poolConfig(poolId) -> immutable per-pool configuration.
export async function readPoolConfig() {
  const r = await client.readContract({
    address: ADDRESSES.hook,
    abi: HOOK_ABI,
    functionName: 'poolConfig',
    args: [POOL_ID],
  })
  // viem returns named-tuple as array in declaration order.
  const [
    baseLpFeeBps,
    bufferBps,
    coverageApr,
    secondsPerYear,
    minHoldSeconds,
    maxPayoutPctOfIl,
    maxPayoutPctOfBuffer,
    maxAccruedCoverageMultiple,
    targetBufferSize,
    minCheckpointInterval,
    admin,
  ] = r
  return {
    baseLpFeeBps,
    bufferBps,
    coverageApr,
    secondsPerYear,
    minHoldSeconds,
    maxPayoutPctOfIl,
    maxPayoutPctOfBuffer,
    maxAccruedCoverageMultiple,
    targetBufferSize,
    minCheckpointInterval,
    admin,
  }
}

// positions(poolId, positionKey) -> live PositionState. Note: settlement CLEARS this struct,
// so a closed position reads all-zero / active=false. Callers must fall back to event history.
export async function readPosition(positionKey) {
  const r = await client.readContract({
    address: ADDRESSES.hook,
    abi: HOOK_ABI,
    functionName: 'positions',
    args: [POOL_ID, positionKey],
  })
  const [
    entryAmt0,
    entryAmt1,
    entryTick,
    tickLower,
    tickUpper,
    depositTime,
    lastAccrualTime,
    active,
    entryNotionalStable,
    earnedCoverageStable,
    liquidity,
  ] = r
  return {
    entryAmt0,
    entryAmt1,
    entryTick,
    tickLower,
    tickUpper,
    depositTime,
    lastAccrualTime,
    active,
    entryNotionalStable,
    earnedCoverageStable,
    liquidity,
  }
}

// Current pool tick, read from the PoolManager via extsload (StateLibrary layout).
// v4 stores pools in mapping at POOLS_SLOT = 6; Slot0 packs sqrtPriceX96(160) | tick(24) | ...
export async function readCurrentTick() {
  const POOLS_SLOT = 6n
  const stateSlot = keccak256(
    encodeAbiParameters([{ type: 'bytes32' }, { type: 'uint256' }], [POOL_ID, POOLS_SLOT]),
  )
  const raw = await client.readContract({
    address: ADDRESSES.poolManager,
    abi: POOL_MANAGER_ABI,
    functionName: 'extsload',
    args: [stateSlot],
  })
  const word = BigInt(raw)
  const sqrtPriceX96 = word & ((1n << 160n) - 1n)
  let tick = (word >> 160n) & 0xffffffn
  if (tick >= 0x800000n) tick -= 0x1000000n // sign-extend int24
  return { tick: Number(tick), sqrtPriceX96 }
}

/* //////////////////////////////////////////////////////////////
                       EVENT LOG FETCHING
////////////////////////////////////////////////////////////// */

// Fetch every hook event whose indexed positionKey (topic2) matches, across DEPLOY_BLOCK..latest,
// chunked to stay within public-RPC block-range limits. Returns raw logs (undecoded).
export async function fetchPositionLogs(positionKey) {
  const latest = await client.getBlockNumber()
  const step = 9000n
  const logs = []
  for (let from = DEPLOY_BLOCK; from <= latest; from += step + 1n) {
    const to = from + step > latest ? latest : from + step
    // topics: [topic0=any event, topic1=any poolId, topic2=positionKey]
    const chunk = await client.request({
      method: 'eth_getLogs',
      params: [
        {
          address: ADDRESSES.hook,
          topics: [null, null, positionKey],
          fromBlock: `0x${from.toString(16)}`,
          toBlock: `0x${to.toString(16)}`,
        },
      ],
    })
    logs.push(...chunk)
  }
  return logs
}

// Resolve block timestamps for a set of logs (events without their own timestamp field need this).
export async function fetchBlockTimestamps(blockNumbers) {
  const unique = [...new Set(blockNumbers.map((b) => BigInt(b)))]
  const entries = await Promise.all(
    unique.map(async (bn) => {
      const block = await client.getBlock({ blockNumber: bn })
      return [bn.toString(), Number(block.timestamp)]
    }),
  )
  return Object.fromEntries(entries)
}
