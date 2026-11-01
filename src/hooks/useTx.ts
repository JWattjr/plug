import { useCallback, useState } from 'react'
import type { Hash, TransactionReceipt } from 'viem'
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from 'wagmi'
import { parseOnchainError } from '@/lib/errors'
import { PLUG } from '@/plug.config'
import { useRefreshPlug } from '@/hooks/useCampaigns'

/** Give up waiting for a receipt after this long and ask the user to check the explorer. Tests shorten it. */
export const TX_TIMING = { receiptTimeoutMs: 120_000 }

export type TxState =
  | { status: 'idle' }
  | { status: 'wallet' }
  | { status: 'confirming'; hash: Hash }
  | { status: 'success'; hash: Hash; receipt: TransactionReceipt }
  /** `hash` is set when the transaction was sent but its outcome could not be confirmed. Do not resend. */
  | { status: 'error'; message: string; hash?: Hash }

/**
 * One transaction at a time: switches the wallet to the right network, asks for a
 * signature, then waits for the real receipt. Every state is read from the wallet
 * or the chain, never timed.
 */
export function useTx() {
  const { chainId } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const client = usePublicClient({ chainId: PLUG.chainId })
  const refresh = useRefreshPlug()
  const [state, setState] = useState<TxState>({ status: 'idle' })

  const reset = useCallback(() => setState({ status: 'idle' }), [])

  const run = useCallback(
    async (send: () => Promise<Hash>): Promise<TransactionReceipt | null> => {
      setState({ status: 'wallet' })
      let sentHash: Hash | undefined
      try {
        if (chainId !== PLUG.chainId) await switchChainAsync({ chainId: PLUG.chainId })
        const hash = await send()
        sentHash = hash
        setState({ status: 'confirming', hash })
        if (!client) throw new Error('network: no RPC client')
        const receipt = await client.waitForTransactionReceipt({ hash, pollingInterval: 1000, timeout: TX_TIMING.receiptTimeoutMs })
        if (receipt.status !== 'success') {
          // A mined revert is final: the transaction did nothing, so it is safe to try again.
          sentHash = undefined
          throw new Error('Transaction reverted')
        }
        setState({ status: 'success', hash, receipt })
        await refresh()
        return receipt
      } catch (error) {
        const message = parseOnchainError(error)
        if (message !== null) console.error('[plug] transaction failed', error)
        if (sentHash) {
          // The wallet already broadcast it. A failed receipt lookup says nothing about the outcome.
          setState({
            status: 'error',
            hash: sentHash,
            message: 'Your transaction was sent, but we could not confirm it yet. Check it on the explorer before sending anything again.',
          })
        } else {
          setState(message === null ? { status: 'idle' } : { status: 'error', message })
        }
        return null
      }
    },
    [chainId, client, refresh, switchChainAsync],
  )

  const busy = state.status === 'wallet' || state.status === 'confirming'
  return { state, run, reset, busy, writeContractAsync }
}
