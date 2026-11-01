import { beforeEach, describe, expect, test } from 'bun:test'
import { custom } from 'viem'
import { arc } from 'viem/chains'
import type { ReadOnlyProvider } from '../src/lib/allowance'
import { clearReadLog, getReadLog, summarizeReadLog } from '../src/lib/readLog'
import { READ_TIMING, resilientTransport } from '../src/lib/readTransport'
import { setWalletReadSource } from '../src/lib/walletReads'

interface Calls {
  http: string[]
  wallet: string[]
}

function setup(opts: {
  http: (method: string) => unknown | Promise<unknown>
  wallet?: { chain?: number; answer?: (method: string) => unknown | Promise<unknown> } | null
}) {
  const calls: Calls = { http: [], wallet: [] }
  const provider: ReadOnlyProvider | undefined = opts.wallet
    ? {
        request: async ({ method }) => {
          calls.wallet.push(method)
          if (method === 'eth_chainId') return `0x${(opts.wallet?.chain ?? 5042).toString(16)}`
          return opts.wallet?.answer ? opts.wallet.answer(method) : '0xabc'
        },
      }
    : undefined
  setWalletReadSource(async () => provider)
  const http = custom({ request: (async ({ method }: { method: string }) => (calls.http.push(method), opts.http(method))) as never }, { retryCount: 0 })
  const transport = resilientTransport({ chainId: 5042, urls: ['https://rpc.mainnet.arc.io/secret-path?key=SECRET'], http })({ chain: arc })
  const request = (method: string) => transport.request({ method, params: [] } as never)
  return { calls, request }
}

const down = () => {
  throw Object.assign(new Error('HTTP request failed. Status: 429. Details: rate limit exceeded'), { status: 429 })
}

beforeEach(() => {
  READ_TIMING.httpBudgetMs = 100
  READ_TIMING.walletTimeoutMs = 200
  clearReadLog()
})

describe('resilientTransport', () => {
  test('a healthy public route answers and the wallet is never asked', async () => {
    const t = setup({ http: () => '0x1', wallet: {} })
    expect(await t.request('eth_blockNumber')).toBe('0x1')
    expect(t.calls.wallet).toEqual([])
    expect(getReadLog()).toHaveLength(0)
  })

  test('a failing public route falls back to the wallet after it reports chain 5042, and both are logged', async () => {
    const t = setup({ http: down, wallet: { answer: () => '0xdead' } })
    expect(await t.request('eth_call')).toBe('0xdead')
    expect(t.calls.wallet).toEqual(['eth_chainId', 'eth_call'])
    const log = getReadLog()
    expect(log.map((e) => `${e.route}:${e.ok}`)).toEqual(['http:false', 'wallet:true'])
    expect(log[0].error?.details).toContain('429')
    expect(summarizeReadLog(log, 60_000).walletAnswers).toHaveLength(1)
  })

  test('a wallet on another chain is rejected and the original public error is what the caller sees', async () => {
    const t = setup({ http: down, wallet: { chain: 1 } })
    await expect(t.request('eth_call')).rejects.toThrow('429')
    expect(t.calls.wallet).toEqual(['eth_chainId']) // the read itself was never sent
    expect(getReadLog().at(-1)?.error?.shortMessage).toContain('Wallet is on chain 1, not 5042')
  })

  test('only allow-listed read methods ever reach the wallet', async () => {
    const t = setup({ http: down, wallet: {} })
    for (const method of ['eth_sendTransaction', 'eth_sendRawTransaction', 'eth_requestAccounts', 'personal_sign', 'wallet_switchEthereumChain', 'eth_signTypedData_v4', 'wallet_requestPermissions']) {
      await expect(t.request(method)).rejects.toThrow()
    }
    expect(t.calls.wallet).toEqual([])
  })

  test('without a connected wallet the public error is returned as is', async () => {
    const t = setup({ http: down, wallet: null })
    await expect(t.request('eth_call')).rejects.toThrow('429')
    expect(t.calls.wallet).toEqual([])
  })

  test('a contract revert is a real answer and is not retried through the wallet', async () => {
    const t = setup({ http: () => { throw new Error('execution reverted') }, wallet: {} })
    await expect(t.request('eth_call')).rejects.toThrow('execution reverted')
    expect(t.calls.wallet).toEqual([])
    expect(getReadLog()).toHaveLength(0)
  })

  test('a hanging public route gives way to the wallet within the budget', async () => {
    const t = setup({ http: () => new Promise(() => undefined), wallet: { answer: () => '0x2' } })
    const started = Date.now()
    expect(await t.request('eth_blockNumber')).toBe('0x2')
    expect(Date.now() - started).toBeLessThan(1000)
    expect(JSON.stringify(getReadLog()[0].error)).toContain('timed out')
  })

  test('a hanging wallet is bounded too, and the public error is reported', async () => {
    const t = setup({ http: down, wallet: { answer: () => new Promise(() => undefined) } })
    const started = Date.now()
    await expect(t.request('eth_call')).rejects.toThrow('429')
    expect(Date.now() - started).toBeLessThan(1500)
  })

  test('"receipt not found" from a lagging public node is double-checked with the wallet', async () => {
    const receipt = { status: '0x1' }
    const t = setup({ http: () => null, wallet: { answer: () => receipt } })
    expect(await t.request('eth_getTransactionReceipt')).toEqual(receipt)
    // If the wallet also has nothing, "not found" stays not found.
    const t2 = setup({ http: () => null, wallet: { answer: () => null } })
    expect(await t2.request('eth_getTransactionReceipt')).toBeNull()
  })

  test('logged failures never contain URL paths or keys', async () => {
    const t = setup({ http: () => { throw new Error('fetch failed for https://rpc.mainnet.arc.io/secret-path?key=SECRET and token=abc123') }, wallet: null })
    await expect(t.request('eth_call')).rejects.toThrow()
    const text = JSON.stringify(getReadLog())
    expect(text).not.toMatch(/secret-path|SECRET|abc123/)
  })
})
