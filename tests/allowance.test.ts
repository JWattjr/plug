import { beforeEach, describe, expect, test } from 'bun:test'
import { HttpRequestError } from 'viem'
import {
  ALLOWANCE_TIMING,
  AllowanceReadError,
  readAllowanceResilient,
  readAllowanceViaWallet,
  type AllowanceReadInput,
  type ReadOnlyProvider,
} from '../src/lib/allowance'
import { buildAllowanceReport } from '../src/lib/allowanceReport'
import { describeError, redact, rpcHost, rpcTransport } from '../src/lib/rpc'
import { resetLogScans, scanLogs } from '../src/hooks/useOrders'
import { fmtUsdc } from '../src/lib/money'
import { PLUG } from '../src/plug.config'
import { ONE_CENT, OWNER, SPENDER, USDC } from './fixtures'

const word = (n: bigint) => `0x${n.toString(16).padStart(64, '0')}`
const HOSTS = ['rpc.mainnet.arc.io']

function input(over: Partial<AllowanceReadInput> = {}): AllowanceReadInput {
  return {
    chainId: 5042,
    token: USDC,
    owner: OWNER,
    spender: SPENDER,
    rpcHosts: HOSTS,
    readBatched: async () => ONE_CENT,
    readDirect: async () => ONE_CENT,
    ...over,
  }
}

const wallet = (chain: number, result: string | Error = word(ONE_CENT)): ReadOnlyProvider & { calls: string[] } => {
  const calls: string[] = []
  return {
    calls,
    request: async ({ method }) => {
      calls.push(method)
      if (method === 'eth_chainId') return `0x${chain.toString(16)}`
      if (method === 'eth_call') {
        if (result instanceof Error) throw result
        return result
      }
      throw new Error(`unexpected ${method}`)
    },
  }
}

beforeEach(() => {
  ALLOWANCE_TIMING.attemptTimeoutMs = 15_000
})

describe('readAllowanceResilient', () => {
  test('uses the normal batched read first and stops there', async () => {
    let direct = 0
    const reading = await readAllowanceResilient(input({ readDirect: async () => (direct++, 0n) }))
    expect(reading.value).toBe(ONE_CENT)
    expect(reading.source).toBe('rpc')
    expect(reading.attempts).toHaveLength(1)
    expect(direct).toBe(0)
  })

  test('a failing batched read falls back to a direct call', async () => {
    const reading = await readAllowanceResilient(input({ readBatched: async () => { throw new Error('HTTP 429') } }))
    expect(reading.source).toBe('rpc-direct')
    expect(reading.value).toBe(ONE_CENT)
    expect(reading.attempts.map((a) => a.ok)).toEqual([false, true])
  })

  test('a successful zero is a real answer, not a failure', async () => {
    const reading = await readAllowanceResilient(input({ readBatched: async () => 0n }))
    expect(reading.value).toBe(0n)
    expect(reading.source).toBe('rpc')
  })

  test('falls back to the wallet when both RPC paths fail, after verifying chain 5042', async () => {
    const provider = wallet(5042)
    const reading = await readAllowanceResilient(
      input({ readBatched: async () => { throw new Error('a') }, readDirect: async () => { throw new Error('b') }, getWalletProvider: async () => provider }),
    )
    expect(reading.source).toBe('wallet')
    expect(reading.value).toBe(ONE_CENT)
    expect(provider.calls).toEqual(['eth_chainId', 'eth_call']) // reads only: no permissions, signing or chain switching
  })

  test('a wallet on another chain is ignored and the failure carries every attempt', async () => {
    const provider = wallet(1)
    const failure = await readAllowanceResilient(
      input({ readBatched: async () => { throw new Error('a') }, readDirect: async () => { throw new Error('b') }, getWalletProvider: async () => provider }),
    ).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(AllowanceReadError)
    const attempts = (failure as AllowanceReadError).attempts
    expect(attempts.map((a) => a.source)).toEqual(['rpc', 'rpc-direct', 'wallet'])
    expect(attempts[2].error?.shortMessage).toContain('Wallet is on chain 1, not 5042')
    expect(provider.calls).toEqual(['eth_chainId']) // never even asked for the allowance
  })

  test('a malformed wallet answer is rejected', async () => {
    await expect(readAllowanceViaWallet(wallet(5042, '0x1234'), { chainId: 5042, token: USDC, owner: OWNER, spender: SPENDER })).rejects.toThrow('malformed')
  })

  test('no wallet connection is an attempt failure, not a zero', async () => {
    const failure = await readAllowanceResilient(
      input({ readBatched: async () => { throw new Error('a') }, readDirect: async () => { throw new Error('b') } }),
    ).catch((e: unknown) => e)
    expect(failure).toBeInstanceOf(AllowanceReadError)
  })

  test('a non-numeric answer from a path is a failure, not a value', async () => {
    const reading = await readAllowanceResilient(input({ readBatched: async () => undefined }))
    expect(reading.source).toBe('rpc-direct')
  })

  test('a hanging path times out and the next path runs', async () => {
    ALLOWANCE_TIMING.attemptTimeoutMs = 30
    const reading = await readAllowanceResilient(input({ readBatched: () => new Promise(() => undefined) }))
    expect(reading.source).toBe('rpc-direct')
    expect(reading.attempts[0].error?.shortMessage).toContain('timed out')
  })
})

describe('error details and redaction', () => {
  test('keeps HTTP status and the server message, and names only the host', () => {
    const error = new HttpRequestError({ url: 'https://rpc.mainnet.arc.io/v1/SECRETKEY123?token=abc', status: 429, body: {}, details: 'Request exceeds defined limit. rate limit exceeded' })
    const d = describeError(error)
    expect(d.status).toBe(429)
    expect(d.details).toContain('rate limit exceeded')
    expect(d.host).toBe('rpc.mainnet.arc.io')
    expect(JSON.stringify(d)).not.toContain('SECRETKEY123')
    expect(JSON.stringify(d)).not.toContain('abc')
  })

  test('redact strips URL paths, query keys, bearer tokens and key=value secrets', () => {
    const out = redact('GET https://eth.example.com/v2/abcdef123456?apikey=zzz failed; Authorization: Bearer sk_live_123; api_key=hunter2 token: t0k3n')
    expect(out).not.toMatch(/abcdef123456|zzz|sk_live_123|hunter2|t0k3n/)
    expect(out).toContain('eth.example.com')
  })

  test('rpcHost drops everything but the host', () => {
    expect(rpcHost('https://user:pw@rpc.example.com:8545/path?key=1')).toBe('rpc.example.com:8545')
    expect(rpcHost('not a url')).toBe('invalid RPC URL')
  })
})

describe('diagnostics report', () => {
  const base = { targetChainId: 5042, targetChainName: 'Arc', spender: SPENDER, token: USDC, rpcHosts: HOSTS, format: fmtUsdc } as const

  test('shows owner, networks, spender, hosts and every attempt, without secrets', async () => {
    const failure = await readAllowanceResilient(
      input({
        readBatched: async () => { throw new HttpRequestError({ url: 'https://rpc.mainnet.arc.io/?_rpc_token=SECRET', status: 429, body: {}, details: 'rate limit exceeded' }) },
        readDirect: async () => { throw new Error('fetch failed for https://rpc.mainnet.arc.io/key/SECRET') },
      }),
    ).catch((e: unknown) => e)
    const text = buildAllowanceReport({ ...base, owner: OWNER, walletChainId: 5042, needed: '0.01 USDC', error: failure }).join('\n')
    expect(text).toContain(`Connected account: ${OWNER}`)
    expect(text).toContain('Target network: Arc (chain 5042)')
    expect(text).toContain(`Spender (Plug): ${SPENDER}`)
    expect(text).toContain('RPC hosts: rpc.mainnet.arc.io')
    expect(text).toContain('Attempt 1: Arc RPC (batched)')
    expect(text).toContain('HTTP 429')
    expect(text).toContain('rate limit exceeded')
    expect(text).toContain('Attempt 2: Arc RPC (direct call)')
    expect(text).not.toContain('SECRET')
  })

  test('a successful read is reported with its source', async () => {
    const reading = await readAllowanceResilient(input())
    const text = buildAllowanceReport({ ...base, owner: OWNER, reading }).join('\n')
    expect(text).toContain('Result: 0.01 USDC via Arc RPC (batched)')
  })
})

describe('configured endpoints', () => {
  test('the registry endpoint leads and the chain\'s other published endpoints back it up', () => {
    expect(PLUG.rpcUrls[0]).toBe('https://rpc.mainnet.arc.io')
    expect(PLUG.rpcUrls.length).toBeGreaterThan(1)
    expect(new Set(PLUG.rpcUrls).size).toBe(PLUG.rpcUrls.length)
    expect(PLUG.rpcUrls.every((u) => u.startsWith('https://'))).toBe(true)
  })

  test('a single endpoint is used as is; several fail over', () => {
    expect(rpcTransport(['https://a.example'])({ chain: PLUG.chain }).config.type).toBe('http')
    expect(rpcTransport(['https://a.example', 'https://b.example'])({ chain: PLUG.chain }).config.type).toBe('fallback')
  })
})

describe('event log scan', () => {
  const ADDR = SPENDER
  beforeEach(() => resetLogScans())

  const client = (handler: (from: bigint, to: bigint) => unknown[]) => {
    const ranges: [bigint, bigint][] = []
    return {
      ranges,
      getLogs: async ({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) => {
        ranges.push([fromBlock, toBlock])
        return handler(fromBlock, toBlock)
      },
    }
  }

  test('reads in 5000-block chunks without probing oversized ranges', async () => {
    const c = client(() => [])
    await scanLogs(c as never, ADDR, 1_000n, 12_999n)
    expect(c.ranges.map(([f, t]) => t - f + 1n)).toEqual([5000n, 5000n, 2000n])
  })

  test('only new blocks are read on the next pass', async () => {
    const c = client((f) => [{ n: f }])
    await scanLogs(c as never, ADDR, 0n, 9_999n)
    const before = c.ranges.length
    const logs = await scanLogs(c as never, ADDR, 0n, 12_000n)
    expect(c.ranges.slice(before)).toEqual([[10_000n, 12_000n]])
    expect(logs).toHaveLength(3)
  })

  test('a rate limit keeps progress and resumes where it stopped, without shrinking the chunk', async () => {
    let calls = 0
    const c = client(() => {
      calls++
      if (calls === 2) throw Object.assign(new Error('rate'), { details: 'Request exceeds defined limit. rate limit exceeded' })
      return []
    })
    await expect(scanLogs(c as never, ADDR, 0n, 14_999n)).rejects.toThrow('rate')
    await scanLogs(c as never, ADDR, 0n, 14_999n)
    expect(c.ranges.map(([f, t]) => `${f}-${t}`)).toEqual(['0-4999', '5000-9999', '5000-9999', '10000-14999'])
  })

  test('a "range too large" answer halves the chunk', async () => {
    const c = client((f, t) => {
      if (t - f + 1n > 2500n) throw Object.assign(new Error('x'), { details: 'requested range too large' })
      return []
    })
    await scanLogs(c as never, ADDR, 0n, 4_999n)
    expect(c.ranges.at(-1)).toEqual([2500n, 4999n])
  })
})
