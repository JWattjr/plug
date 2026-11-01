import { useCallback, useRef, useState } from 'react'
import { erc20Abi } from 'viem'
import { useTx } from '@/hooks/useTx'
import { useUsdcAllowance } from '@/hooks/useUsdc'
import { approvalKey, approvedAmountFromReceipt, resolveApprovalGate } from '@/lib/approval'
import { PLUG } from '@/plug.config'

/**
 * USDC approval flow shared by every screen that spends through Plug.
 *
 * - The allowance is unknown until read. Unknown or failed reads never offer a paid
 *   approval; `gate.kind` is 'loading' or 'error' with a retry instead.
 * - Right before an approval is sent, the allowance is re-read. If that read fails, or
 *   already covers `required`, nothing is sent.
 * - A mined approval receipt is verified against its Approval event for this chain,
 *   token, owner and spender before it advances the flow. A different account or
 *   network never inherits it.
 * - If an approval was sent but its receipt could not be fetched, `unconfirmed` is set.
 *   The flow keeps watching the chain and advances once the allowance shows up.
 */
export function useApproval(owner: `0x${string}` | undefined, required: bigint) {
  const allowance = useUsdcAllowance(owner)
  const [verifying, setVerifying] = useState(false)
  const inFlight = useRef(false)
  const [proof, setProof] = useState<{ key: string; amount: bigint } | null>(null)

  const key = owner && PLUG.usdcAddress && PLUG.address ? approvalKey(PLUG.chainId, PLUG.usdcAddress, owner, PLUG.address) : undefined
  // An approval confirmed later (status check or reload) is verified the same way as one confirmed in place.
  const approveTx = useTx({
    scope: 'approve-usdc',
    onRecovered: (receipt) => {
      if (!owner || !key || !PLUG.usdcAddress || !PLUG.address) return
      const amount = approvedAmountFromReceipt(receipt, { token: PLUG.usdcAddress, owner, spender: PLUG.address })
      if (amount > 0n) setProof({ key, amount })
    },
  })
  const receiptAmount = proof !== null && proof.key === key ? proof.amount : 0n

  const gate = resolveApprovalGate({
    budget: required,
    receiptAmount,
    read: {
      data: allowance.data?.value,
      isPending: allowance.isPending,
      isError: allowance.isError,
      isIdle: allowance.fetchStatus === 'idle' && allowance.data === undefined,
    },
  })

  const unconfirmed = approveTx.unresolved

  const { refetch } = allowance
  const retry = useCallback(() => {
    void refetch()
  }, [refetch])

  /** Forget receipt proof, e.g. after the allowance has been spent by creating a campaign. */
  const clearProof = useCallback(() => setProof(null), [])

  /** Returns true when the allowance covers `required` afterwards. Never sends on an unknown read. */
  const approve = useCallback(async (): Promise<boolean> => {
    if (!owner || !key || !PLUG.usdcAddress || !PLUG.address || required <= 0n) return false
    // One approval attempt at a time: a second click while the allowance is being re-read must not send twice.
    if (inFlight.current) return false
    inFlight.current = true
    const token = PLUG.usdcAddress
    const spender = PLUG.address
    try {
      // Never pay for an approval on a stale or failed read.
      setVerifying(true)
      const fresh = await refetch()
      setVerifying(false)
      if (fresh.isError || fresh.data === undefined) return false
      if (fresh.data.value >= required) return true

      const receipt = await approveTx.run(() =>
        approveTx.writeContractAsync({ address: token, abi: erc20Abi, functionName: 'approve', args: [spender, required], chainId: PLUG.chainId }),
      )
      if (!receipt) return false
      const amount = approvedAmountFromReceipt(receipt, { token, owner, spender })
      if (amount > 0n) setProof({ key, amount })
      return true
    } finally {
      setVerifying(false)
      inFlight.current = false
    }
  }, [approveTx, key, owner, refetch, required])

  return {
    gate,
    approve,
    retry,
    retrying: allowance.isFetching,
    approveTx,
    /** Re-reading the allowance or waiting on the wallet or chain for an approval. */
    busy: verifying || approveTx.busy,
    unconfirmed,
    clearProof,
    owner,
    /** The last successful read: value, which path answered, and every attempt. */
    reading: allowance.data,
    /** Set when the latest read failed. An AllowanceReadError carries every attempt. */
    error: allowance.error ?? undefined,
  }
}
