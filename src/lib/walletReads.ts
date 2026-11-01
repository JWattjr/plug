import type { Config } from 'wagmi'
import { getAccount } from 'wagmi/actions'
import type { ReadOnlyProvider } from '@/lib/allowance'

/**
 * Read-only access to the connected wallet's own network connection.
 *
 * Only the methods below are ever sent to a wallet by the read path. Nothing here requests
 * accounts or permissions, signs, sends, or switches networks. Every answer is accepted only
 * after the wallet reports the configured chain id.
 */
export const WALLET_READ_METHODS: ReadonlySet<string> = new Set([
  'eth_call',
  'eth_getTransactionReceipt',
  'eth_getTransactionByHash',
  'eth_blockNumber',
  'eth_getBlockByNumber',
  'eth_getLogs',
  'eth_getBalance',
  'eth_getCode',
])

type Source = () => Promise<ReadOnlyProvider | undefined>
let source: Source | undefined

export function setWalletReadSource(next: Source | undefined): void {
  source = next
}

/** Point the read path at whichever connector is connected right now. Call once after createConfig. */
export function bindWalletReads(config: Config): void {
  setWalletReadSource(async () => {
    const account = getAccount(config)
    if (account.status !== 'connected' || !account.connector) return undefined
    return (await account.connector.getProvider()) as ReadOnlyProvider | undefined
  })
}

export async function getWalletReadProvider(): Promise<ReadOnlyProvider | undefined> {
  try {
    return await source?.()
  } catch {
    return undefined
  }
}

/** Throws unless the wallet reports `chainId`. Uses only eth_chainId. */
export async function assertWalletChain(provider: ReadOnlyProvider, chainId: number): Promise<void> {
  const reported = await provider.request({ method: 'eth_chainId' })
  const walletChain = typeof reported === 'string' ? Number.parseInt(reported, 16) : Number.NaN
  if (walletChain !== chainId) {
    throw new Error(`Wallet is on chain ${Number.isFinite(walletChain) ? walletChain : 'unknown'}, not ${chainId}. Its answer was ignored.`)
  }
}
