import { useCallback, useEffect, useRef, useState } from 'react'
import { TransactionReceiptNotFoundError, type Hash, type PublicClient, type TransactionReceipt } from 'viem'
import { useAccount, usePublicClient, useSwitchChain, useWriteContract } from 'wagmi'
import { parseOnchainError } from '@/lib/errors'
import { clearPending, loadPending, pendingKey, savePending } from '@/lib/pendingTx'
import { describeError } from '@/lib/rpc'
import { PLUG } from '@/plug.config'
import { useRefreshPlug } from '@/hooks/useCampaigns'

export type TxState =
  | { status: 'idle' }
  | { status: 'wallet' }
  | { status: 'confirming'; hash: Hash }
  | { status: 'success'; hash: Hash; receipt: TransactionReceipt }
  /** Sent, but its outcome could not be read. It may still succeed, so it must not be repeated. */
  | { status: 'unresolved'; hash: Hash; message: string }
  | { status: 'error'; message: string }

/** Tests shorten these. `receiptTimeoutMs` bounds how long one send waits before asking the user to check status. */
export const TX_TIMING = { receiptTimeoutMs: 120_000, pollMs: 1_500 }

type Outcome =
  | { kind: 'success'; receipt: TransactionReceipt }
  | { kind: 'reverted' }
  | { kind: 'pending'; lastError?: string }

async function readReceipt(client: Pick<PublicClient, 'getTransactionReceipt'>, hash: Hash): Promise<TransactionReceipt | null> {
  try {
    return await client.getTransactionReceipt({ hash })
  } catch (error) {
    if (error instanceof TransactionReceiptNotFoundError) return null
    throw error
  }
}

/** One read-only look at a hash. A failed read is reported as pending, with the reason, never as a result. */
async function lookupOnce(client: Pick<PublicClient, 'getTransactionReceipt'>, hash: Hash): Promise<Outcome> {
  try {
    const receipt = await readReceipt(client, hash)
    if (!receipt) return { kind: 'pending' }
    return receipt.status === 'success' ? { kind: 'success', receipt } : { kind: 'reverted' }
  } catch (error) {
    return { kind: 'pending', lastError: describeError(error).shortMessage }
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

/**
 * Poll for a receipt for at most `timeoutMs`. Read failures never end the wait early and never
 * look like a result: the last one is reported if the deadline passes with no receipt.
 */
async function pollReceipt(client: Pick<PublicClient, 'getTransactionReceipt'>, hash: Hash, timeoutMs: number): Promise<Outcome> {
  const deadline = Date.now() + timeoutMs
  let lastError: string | undefined
  for (;;) {
    try {
      const receipt = await readReceipt(client, hash)
      if (receipt) return receipt.status === 'success' ? { kind: 'success', receipt } : { kind: 'reverted' }
      lastError = undefined
    } catch (error) {
      lastError = describeError(error).shortMessage
    }
    if (Date.now() >= deadline) return { kind: 'pending', lastError }
    await sleep(Math.min(TX_TIMING.pollMs, Math.max(0, deadline - Date.now())))
  }
}

interface TxOptions {
  /** Names the action (for example "create-campaign"). A sent hash is remembered under it so a reload can check status. */
  scope?: string
  /** Called with the receipt when a previously sent transaction is confirmed by a status check. */
  onRecovered?: (receipt: TransactionReceipt) => void | Promise<void>
}

const UNRESOLVED_MESSAGE =
  'Your transaction was sent, but we could not confirm it yet. Check its status below before sending anything again.'

/**
 * One transaction at a time: switches the wallet to the right network, asks for a
 * signature, then waits for the real receipt. Every state is read from the wallet
 * or the chain, never timed.
 *
 * Once a hash exists the outcome is never guessed. If it cannot be read, the state is
 * 'unresolved' (also after a reload, when a scope is given) and `checkStatus` re-reads it
 * without sending anything. A confirmed success is never downgraded by a later read failure.
 */
export function useTx(options: TxOptions = {}) {
  const { chainId, address } = useAccount()
  const { switchChainAsync } = useSwitchChain()
  const { writeContractAsync } = useWriteContract()
  const client = usePublicClient({ chainId: PLUG.chainId })
  const refresh = useRefreshPlug()
  const [rawState, setState] = useState<TxState>({ status: 'idle' })
  const [checking, setChecking] = useState(false)

  const storeKey = options.scope ? pendingKey({ chainId: PLUG.chainId, contract: PLUG.address, account: address, scope: options.scope }) : undefined
  // Another account has its own state: drop this one when the account (and so the store key) changes.
  const [seenKey, setSeenKey] = useState(storeKey)
  if (seenKey !== storeKey) {
    setSeenKey(storeKey)
    setState({ status: 'idle' })
  }

  const latest = useRef({ storeKey, onRecovered: options.onRecovered, client, refresh })
  useEffect(() => {
    latest.current = { storeKey, onRecovered: options.onRecovered, client, refresh }
  })

  // A hash remembered from before a reload counts as unresolved until it is checked.
  const stored = rawState.status === 'idle' ? loadPending(storeKey) : undefined
  const state: TxState = stored
    ? { status: 'unresolved', hash: stored.hash, message: `${UNRESOLVED_MESSAGE} It was sent earlier from this browser.` }
    : rawState
  const knownHash = state.status === 'unresolved' || state.status === 'confirming' ? state.hash : undefined

  const reset = useCallback(() => {
    clearPending(latest.current.storeKey)
    setState({ status: 'idle' })
    setSeenKey((k) => k) // re-render even when already idle so the cleared hash disappears
    setChecking(false)
  }, [])

  /** Refresh reads after a confirmed result. A failing refresh must never undo that result. */
  const refreshQuietly = useCallback(async () => {
    try {
      await latest.current.refresh()
    } catch (error) {
      console.warn('[plug] refresh after confirmed transaction failed', error)
    }
  }, [])

  const settle = useCallback(
    async (hash: Hash, outcome: Outcome, recovered: boolean): Promise<TransactionReceipt | null> => {
      if (outcome.kind === 'success') {
        clearPending(latest.current.storeKey)
        setState({ status: 'success', hash, receipt: outcome.receipt })
        if (recovered) {
          try {
            await latest.current.onRecovered?.(outcome.receipt)
          } catch (error) {
            console.warn('[plug] handling a recovered transaction failed', error)
          }
        }
        await refreshQuietly()
        return outcome.receipt
      }
      if (outcome.kind === 'reverted') {
        // A mined revert is final: the transaction did nothing, so it is safe to try again.
        clearPending(latest.current.storeKey)
        setState({ status: 'error', message: 'The transaction was rejected by the contract. Refresh and try again.' })
        return null
      }
      setState({
        status: 'unresolved',
        hash,
        message: outcome.lastError ? `${UNRESOLVED_MESSAGE} Last read problem: ${outcome.lastError}.` : UNRESOLVED_MESSAGE,
      })
      return null
    },
    [refreshQuietly],
  )

  const run = useCallback(
    async (send: () => Promise<Hash>): Promise<TransactionReceipt | null> => {
      setState({ status: 'wallet' })
      let hash: Hash
      try {
        if (chainId !== PLUG.chainId) await switchChainAsync({ chainId: PLUG.chainId })
        hash = await send()
      } catch (error) {
        const message = parseOnchainError(error)
        if (message !== null) console.error('[plug] transaction failed', error)
        setState(message === null ? { status: 'idle' } : { status: 'error', message })
        return null
      }

      // The wallet has broadcast it. From here on nothing may look like "nothing happened".
      savePending(latest.current.storeKey, hash)
      setState({ status: 'confirming', hash })
      const reader = latest.current.client
      if (!reader) return settle(hash, { kind: 'pending', lastError: 'no RPC client' }, false)
      return settle(hash, await pollReceipt(reader, hash, TX_TIMING.receiptTimeoutMs), false)
    },
    [chainId, settle, switchChainAsync],
  )

  /** Read-only: look up the receipt of the hash already sent. Never sends or signs anything. */
  const checkStatus = useCallback(async (): Promise<TransactionReceipt | null> => {
    const hash = knownHash
    const reader = latest.current.client
    if (!hash || !reader) return null
    setChecking(true)
    try {
      return await settle(hash, await lookupOnce(reader, hash), true)
    } finally {
      setChecking(false)
    }
  }, [knownHash, settle])

  // After a reload (or an account switch) check a remembered hash once, read-only.
  const restoredFor = useRef<string | undefined>(undefined)
  useEffect(() => {
    if (!storeKey || restoredFor.current === storeKey) return
    restoredFor.current = storeKey
    const pending = loadPending(storeKey)
    const reader = latest.current.client
    if (!pending || !reader) return
    void (async () => {
      setChecking(true)
      try {
        await settle(pending.hash, await lookupOnce(reader, pending.hash), true)
      } finally {
        setChecking(false)
      }
    })()
  }, [settle, storeKey])

  const busy = state.status === 'wallet' || state.status === 'confirming' || checking
  const unresolved = state.status === 'unresolved'
  /** Busy, or sent and unconfirmed: either way no second send may start from this hook. */
  const locked = busy || unresolved
  return { state, run, reset, busy, locked, unresolved, checking, checkStatus, writeContractAsync }
}
