import { decodeAbiParameters, encodeFunctionData, erc20Abi, type Hex } from 'viem'
import { describeError, rpcHost, type DescribedError } from '@/lib/rpc'

/**
 * Reading "how much USDC has this account allowed Plug" without ever guessing.
 *
 * Three independent, read-only paths are tried in order and the first verified answer wins:
 *   1. rpc         the app's normal batched read over the configured endpoints
 *   2. rpc-direct  a plain, unbatched eth_call over the same endpoints
 *   3. wallet      the connected wallet's own node, accepted only on the target chain
 * If none answers, the failure carries every attempt so the screen can show the real cause.
 * Nothing here signs, requests permissions or switches networks.
 */

export type ReadSource = 'rpc' | 'rpc-direct' | 'wallet'

export const SOURCE_LABEL: Record<ReadSource, string> = {
  rpc: 'Arc RPC (batched)',
  'rpc-direct': 'Arc RPC (direct call)',
  wallet: 'Connected wallet network',
}

export interface ReadAttempt {
  source: ReadSource
  ok: boolean
  ms: number
  /** Hosts this attempt talked to. Hostnames only, never full URLs. */
  hosts: string[]
  value?: bigint
  error?: DescribedError
}

export interface AllowanceReading {
  value: bigint
  source: ReadSource
  attempts: ReadAttempt[]
  checkedAt: number
}

export class AllowanceReadError extends Error {
  attempts: ReadAttempt[]
  checkedAt: number
  constructor(attempts: ReadAttempt[]) {
    super('Could not read the USDC allowance from any source')
    this.name = 'AllowanceReadError'
    this.attempts = attempts
    this.checkedAt = Date.now()
  }
}

/** Minimal EIP-1193 surface. Only read methods are ever called on it. */
export interface ReadOnlyProvider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>
}

export interface AllowanceReadInput {
  chainId: number
  token: `0x${string}`
  owner: `0x${string}`
  spender: `0x${string}`
  /** Hosts of the configured endpoints, for diagnostics. */
  rpcHosts: string[]
  readBatched: () => Promise<unknown>
  readDirect: () => Promise<unknown>
  /** The connected wallet's provider, if any. */
  getWalletProvider?: () => Promise<ReadOnlyProvider | undefined>
}

export const ALLOWANCE_TIMING = { attemptTimeoutMs: 15_000 }

function withTimeout<T>(work: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${Math.round(ms / 1000)}s`)), ms)
  })
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer))
}

function asUint(value: unknown): bigint {
  if (typeof value !== 'bigint' || value < 0n) throw new Error('Allowance read returned an unexpected value')
  return value
}

/** Read allowance(owner, spender) through the connected wallet, only if it is on `chainId`. */
export async function readAllowanceViaWallet(provider: ReadOnlyProvider, input: Pick<AllowanceReadInput, 'chainId' | 'token' | 'owner' | 'spender'>): Promise<bigint> {
  const reported = await provider.request({ method: 'eth_chainId' })
  const walletChain = typeof reported === 'string' ? Number.parseInt(reported, 16) : Number.NaN
  if (walletChain !== input.chainId) {
    throw new Error(`Wallet is on chain ${Number.isFinite(walletChain) ? walletChain : 'unknown'}, not ${input.chainId}. Its answer was ignored.`)
  }
  const data = encodeFunctionData({ abi: erc20Abi, functionName: 'allowance', args: [input.owner, input.spender] })
  const result = await provider.request({ method: 'eth_call', params: [{ to: input.token, data }, 'latest'] })
  if (typeof result !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(result)) throw new Error('Wallet returned a malformed allowance')
  const [value] = decodeAbiParameters([{ type: 'uint256' }], result as Hex)
  return value
}

export async function readAllowanceResilient(input: AllowanceReadInput): Promise<AllowanceReading> {
  const attempts: ReadAttempt[] = []
  const limit = ALLOWANCE_TIMING.attemptTimeoutMs

  async function attempt(source: ReadSource, hosts: string[], run: () => Promise<unknown>): Promise<bigint | undefined> {
    const started = Date.now()
    try {
      const value = asUint(await withTimeout(run(), limit, SOURCE_LABEL[source]))
      attempts.push({ source, ok: true, ms: Date.now() - started, hosts, value })
      return value
    } catch (error) {
      attempts.push({ source, ok: false, ms: Date.now() - started, hosts, error: describeError(error) })
      return undefined
    }
  }

  const done = (value: bigint, source: ReadSource): AllowanceReading => ({ value, source, attempts, checkedAt: Date.now() })

  const batched = await attempt('rpc', input.rpcHosts, input.readBatched)
  if (batched !== undefined) return done(batched, 'rpc')

  const direct = await attempt('rpc-direct', input.rpcHosts, input.readDirect)
  if (direct !== undefined) return done(direct, 'rpc-direct')

  const walletHosts = ['wallet']
  const viaWallet = await attempt('wallet', walletHosts, async () => {
    const provider = await input.getWalletProvider?.()
    if (!provider) throw new Error('No wallet connection to read through')
    return readAllowanceViaWallet(provider, input)
  })
  if (viaWallet !== undefined) return done(viaWallet, 'wallet')

  throw new AllowanceReadError(attempts)
}

export { rpcHost }
