import { custom, type Transport } from 'viem'
import type { ReadOnlyProvider } from '@/lib/allowance'
import { recordRead } from '@/lib/readLog'
import { describeError, rpcHost } from '@/lib/rpc'
import { assertWalletChain, getWalletReadProvider, WALLET_READ_METHODS } from '@/lib/walletReads'

/** How long the public route gets before the connected wallet is asked, so a dead route cannot stall a screen. */
export const READ_TIMING = { httpBudgetMs: 8_000, walletTimeoutMs: 10_000 }

const NOT_FOUND_IS_SUSPECT: ReadonlySet<string> = new Set(['eth_getTransactionReceipt', 'eth_getTransactionByHash'])

function withTimeout<T>(work: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} timed out after ${Math.round(ms / 1000)}s`)), ms)
  })
  work.catch(() => undefined) // a request abandoned by the timeout must not surface as an unhandled rejection
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer))
}

/** A contract revert is a real answer. Asking another node would only repeat it. */
function isDeterministic(error: unknown): boolean {
  const { shortMessage, details, code } = describeError(error)
  return code === 3 || /execution reverted/i.test(`${shortMessage} ${details ?? ''}`)
}

/**
 * Reads go to the public Arc endpoints first. If those fail, an allow-listed read-only method is
 * retried through the connected wallet's own connection, after the wallet reports the configured
 * chain. Unconnected visitors use the public endpoints alone. Every failure and every wallet
 * answer is written to the read log. Transactions never pass through here.
 */
export function resilientTransport(options: { chainId: number; urls: readonly string[]; http: Transport }): Transport {
  const hosts = options.urls.map(rpcHost)

  return (params) => {
    const inner = options.http({ ...params, retryCount: 0 })

    async function request({ method, params: rpcParams }: { method: string; params?: unknown }): Promise<unknown> {
      const send = () => inner.request({ method, params: rpcParams } as never)
      const wallet = WALLET_READ_METHODS.has(method) ? await getWalletReadProvider() : undefined
      const started = Date.now()
      try {
        // With a wallet to fall back on, the public route gets a bounded turn. Without one, its own timeouts apply.
        const answer = wallet ? await withTimeout(send(), READ_TIMING.httpBudgetMs, 'Arc RPC') : await send()
        // "Not found" from one public node can just mean it is behind. Ask the wallet's node before believing it.
        if (answer === null && wallet && NOT_FOUND_IS_SUSPECT.has(method)) {
          try {
            const second = await viaWallet(wallet, method, rpcParams, undefined)
            return second ?? answer
          } catch {
            return answer
          }
        }
        return answer
      } catch (httpError) {
        if (isDeterministic(httpError)) throw httpError
        recordRead({ method, route: 'http', ok: false, ms: Date.now() - started, hosts, error: describeError(httpError) })
        if (!wallet) throw httpError
        return viaWallet(wallet, method, rpcParams, httpError)
      }
    }

    async function viaWallet(provider: ReadOnlyProvider, method: string, rpcParams: unknown, httpError?: unknown): Promise<unknown> {
      const started = Date.now()
      try {
        await withTimeout(assertWalletChain(provider, options.chainId), READ_TIMING.walletTimeoutMs, 'Wallet chain check')
        const result = await withTimeout(
          provider.request({ method, params: rpcParams as unknown[] | undefined }),
          READ_TIMING.walletTimeoutMs,
          'Wallet read',
        )
        recordRead({ method, route: 'wallet', ok: true, ms: Date.now() - started, hosts: ['wallet'] })
        return result
      } catch (walletError) {
        if (isDeterministic(walletError)) throw walletError
        recordRead({ method, route: 'wallet', ok: false, ms: Date.now() - started, hosts: ['wallet'], error: describeError(walletError) })
        throw httpError ?? walletError
      }
    }

    return custom({ request: request as never }, { retryCount: 0 })(params)
  }
}
