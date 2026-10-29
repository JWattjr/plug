import { useRef, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { erc20Abi, isAddress, parseEventLogs } from 'viem'
import { usePublicClient } from 'wagmi'
import { ArrowUpRight, Bot, Megaphone, ShieldCheck, Store } from 'lucide-react'
import { ErrorNote, Page, Skeleton, Spinner, SponsoredBadge, Step, TxLink, TxNotice, type StepStatus } from '@/components/ui'
import { SplitVisual } from '@/components/SplitVisual'
import { ProtectionBadge } from '@/components/ProtectionBadge'
import { PLUG_QUERY_KEY, useNow } from '@/hooks/useCampaigns'
import { useTx } from '@/hooks/useTx'
import { useUsdcAllowance, useUsdcBalance } from '@/hooks/useUsdc'
import { useWalletGate } from '@/hooks/useWalletGate'
import { isLive, isProtected, safeHref, type Campaign } from '@/lib/campaigns'
import { explainCommission, UNDELIVERABLE_REASON } from '@/lib/commission'
import { fmtBps, fmtUsdc, sameAddress, shortAddress } from '@/lib/money'
import { plugAbi } from '@/lib/plugAbi'
import { fmtTimeLeft, fmtWindowLong } from '@/lib/time'
import { PLUG } from '@/plug.config'

interface Receipt {
  hash: `0x${string}`
  price: bigint
  commission: bigint
  referrer: `0x${string}`
  reason?: string
}

function useCampaign(id: bigint | undefined) {
  const client = usePublicClient({ chainId: PLUG.chainId })
  return useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'campaign', PLUG.address, id?.toString()],
    enabled: id !== undefined && Boolean(client && PLUG.address),
    refetchInterval: 8_000,
    retry: false,
    queryFn: async (): Promise<Campaign> => {
      const row = await client!.readContract({ address: PLUG.address!, abi: plugAbi, functionName: 'getCampaign', args: [id!] })
      return { id: id!, ...row }
    },
  })
}

export default function Checkout() {
  const params = useParams()
  const [search] = useSearchParams()
  const id = params.id && /^\d+$/.test(params.id) ? BigInt(params.id) : undefined
  const refParam = search.get('ref') ?? undefined
  const referrer = refParam && isAddress(refParam) ? (refParam) : undefined
  const badRef = Boolean(refParam) && !referrer

  const gate = useWalletGate()
  const now = useNow()
  const { data: campaign, isLoading, error } = useCampaign(id)
  const balance = useUsdcBalance(gate.address)
  const allowance = useUsdcAllowance(gate.address)
  const approveTx = useTx()
  const buyTx = useTx()
  const navigate = useNavigate()
  const [approved, setApproved] = useState(0n)
  const [receipt, setReceipt] = useState<Receipt | null>(null)
  const snapshot = useRef<Campaign | null>(null)

  if (id === undefined) {
    return (
      <Page narrow>
        <ErrorNote>That link is not a valid campaign. <Link className="underline" to="/offers">Browse live offers</Link></ErrorNote>
      </Page>
    )
  }

  if (isLoading || (!campaign && !error)) {
    return (
      <Page>
        <div className="grid gap-6 lg:grid-cols-2">
          <Skeleton className="h-80 !rounded-3xl" />
          <Skeleton className="h-80 !rounded-3xl" />
        </div>
      </Page>
    )
  }

  if (!campaign) {
    return (
      <Page narrow>
        <ErrorNote>
          Campaign #{id.toString()} does not exist on {PLUG.chainName}. <Link className="underline" to="/offers">Browse live offers</Link>
        </ErrorNote>
      </Page>
    )
  }

  const current: Campaign = campaign
  const live = isLive(campaign, now)
  const outlook = explainCommission(campaign, referrer, gate.address)
  const href = safeHref(campaign.offerUrl)
  const price = campaign.price
  const haveBalance = balance.data
  const insufficient = haveBalance !== undefined && haveBalance < price
  const effectiveAllowance = (allowance.data ?? 0n) > approved ? (allowance.data ?? 0n) : approved
  const needsApproval = effectiveAllowance < price
  const busy = approveTx.busy || buyTx.busy
  const protectedOffer = isProtected(campaign)
  const buyerIsArbiter = protectedOffer && sameAddress(campaign.arbiter, gate.address)
  const windowText = fmtWindowLong(campaign.protectionWindow)
  const endedReason = !campaign.active ? 'This campaign was closed by the seller.' : !live ? 'This campaign has ended.' : undefined

  async function approve() {
    if (!PLUG.usdcAddress || !PLUG.address) return
    const done = await approveTx.run(() =>
      approveTx.writeContractAsync({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'approve', args: [PLUG.address!, price], chainId: PLUG.chainId }),
    )
    if (done) setApproved(price)
  }

  async function buy() {
    if (!PLUG.address || id === undefined) return
    snapshot.current = current
    const done = await buyTx.run(() =>
      buyTx.writeContractAsync({
        address: PLUG.address!,
        abi: plugAbi,
        functionName: 'buy',
        args: [id, referrer ?? '0x0000000000000000000000000000000000000000'],
        chainId: PLUG.chainId,
      }),
    )
    if (!done) return
    if (protectedOffer) {
      const [placed] = parseEventLogs({ abi: plugAbi, logs: done.logs, eventName: 'OrderPlaced' }).filter((log) => sameAddress(log.address, PLUG.address))
      if (placed) navigate(`/orders/${placed.args.orderId.toString()}`)
      return
    }
    const [event] = parseEventLogs({ abi: plugAbi, logs: done.logs, eventName: 'Purchase' }).filter(
      (log) => sameAddress(log.address, PLUG.address),
    )
    if (!event) return
    const before = snapshot.current ?? current
    const expected = explainCommission(before, event.args.referrer, event.args.buyer)
    setReceipt({
      hash: done.transactionHash,
      price: event.args.price,
      commission: event.args.commission,
      referrer: event.args.referrer,
      reason: event.args.commission > 0n ? undefined : (expected.reason ?? UNDELIVERABLE_REASON),
    })
  }

  const approveStatus: StepStatus = needsApproval ? 'active' : 'done'
  const buyStatus: StepStatus = needsApproval ? 'todo' : 'active'

  let action: React.ReactNode
  if (!gate.isConnected) action = <button className="btn btn-primary w-full" onClick={gate.connect}>Connect wallet to buy</button>
  else if (gate.wrongNetwork) action = <button className="btn btn-primary w-full" onClick={gate.switchNetwork}>Switch to {PLUG.chainName}</button>
  else if (needsApproval)
    action = (
      <button className="btn btn-primary w-full" disabled={!live || insufficient || busy} onClick={() => void approve()}>
        {approveTx.busy && <Spinner />} Step 1 of 2: Allow {fmtUsdc(price)}
      </button>
    )
  else
    action = (
      <button className="btn btn-primary w-full" disabled={!live || insufficient || busy || buyerIsArbiter} onClick={() => void buy()}>
        {buyTx.busy && <Spinner />} Step 2 of 2: {protectedOffer ? 'Pay into escrow' : 'Buy'} for {fmtUsdc(price)}
      </button>
    )

  return (
    <Page>
      <div className="grid gap-6 lg:grid-cols-[1fr_1.05fr]">
        <section className="card flex flex-col gap-5 p-6 sm:p-7" aria-label="Product">
          <div className="flex items-center justify-between">
            <SponsoredBadge />
            <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>Campaign #{campaign.id.toString()}</span>
          </div>
          <h1 className="display text-balance text-3xl font-bold leading-tight">{campaign.title || 'Untitled offer'}</h1>
          <div className="flex items-baseline gap-2">
            <span className="display text-5xl font-bold tabular-nums">{fmtUsdc(price).replace(' USDC', '')}</span>
            <span style={{ color: 'var(--subtle)' }}>USDC</span>
          </div>
          <div className="space-y-1.5">
            <ProtectionBadge campaign={campaign} />
            {protectedOffer && (
              <p className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }} data-testid="order-counts">
                {campaign.pendingOrders.toString()} pending order{campaign.pendingOrders === 1n ? '' : 's'} · {campaign.refundedCount.toString()} refund{campaign.refundedCount === 1n ? '' : 's'} so far
              </p>
            )}
          </div>
          <dl className="grid grid-cols-2 gap-3 text-sm">
            <div className="inner p-3">
              <dt className="label !mb-1 flex items-center gap-1"><Store className="size-3" /> Seller</dt>
              <dd className="mono text-xs">{shortAddress(campaign.advertiser)}</dd>
            </div>
            <div className="inner p-3">
              <dt className="label !mb-1">Ends in</dt>
              <dd className="font-semibold tabular-nums">{fmtTimeLeft(campaign.endTime, now)}</dd>
            </div>
          </dl>
          {href ? (
            <a href={href} target="_blank" rel="noopener noreferrer nofollow" className="inline-flex items-center gap-1 break-all text-sm underline underline-offset-2" style={{ color: 'var(--accent)' }}>
              {href} <ArrowUpRight className="size-4 shrink-0" />
            </a>
          ) : (
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>This seller did not provide a safe web link.</p>
          )}
        </section>

        <section className="space-y-5" aria-label="Checkout">
          {receipt ? (
            <div className="space-y-4">
              <SplitVisual price={receipt.price} commission={receipt.commission} noCommissionReason={receipt.reason} />
              <div className="card flex flex-wrap items-center justify-between gap-3 p-4">
                <TxLink hash={receipt.hash} label="View transaction on the Arc explorer" />
                {receipt.commission > 0n && (
                  <Link className="text-xs font-semibold underline underline-offset-2" style={{ color: 'var(--agent)' }} to={`/earnings/${receipt.referrer}`}>
                    See the agent&apos;s earnings
                  </Link>
                )}
              </div>
            </div>
          ) : (
            <div className="card space-y-5 p-6 sm:p-7">
              <div className="rounded-2xl border p-4" style={{ background: 'rgba(240,184,107,0.08)', borderColor: 'rgba(240,184,107,0.4)' }}>
                <p className="flex items-center gap-2 text-sm font-semibold" style={{ color: 'var(--agent)' }}>
                  <Megaphone className="size-4" /> This offer is sponsored
                </p>
                <p className="mt-1 text-pretty text-sm" style={{ color: 'var(--muted)' }}>
                  The seller pays the referring agent a {fmtBps(campaign.commissionBps)} commission from its own budget when you buy. You pay the same price either way.
                </p>
              </div>

              <div className="inner flex items-center gap-3 p-4">
                <span className="flex size-9 items-center justify-center rounded-full" style={{ background: 'rgba(240,184,107,0.15)', color: 'var(--agent)' }}>
                  <Bot className="size-4" />
                </span>
                <div className="text-sm">
                  <div className="label !mb-0.5">Referred by</div>
                  {referrer ? <span className="mono text-xs">{shortAddress(referrer)}</span> : <span style={{ color: 'var(--muted)' }}>No agent</span>}
                </div>
              </div>
              {badRef && <p className="text-xs" style={{ color: 'var(--danger)' }}>The referrer in this link is not a valid address, so no agent will be credited.</p>}

              <div className="inner space-y-2 p-4 text-sm tabular-nums">
                <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>You pay</span><span className="font-semibold">{fmtUsdc(price)}</span></div>
                <div className="flex justify-between"><span style={{ color: 'var(--muted)' }}>{protectedOffer ? 'Seller receives after the window' : 'Seller receives'}</span><span style={{ color: 'var(--accent)' }}>{fmtUsdc(price)}</span></div>
                <div className="flex justify-between">
                  <span style={{ color: 'var(--muted)' }}>{protectedOffer ? 'Agent earns if the sale sticks' : 'Agent earns'}</span>
                  <span style={{ color: outlook.commission > 0n ? 'var(--agent)' : 'var(--subtle)' }}>{outlook.commission > 0n ? fmtUsdc(outlook.commission) : 'No commission'}</span>
                </div>
                {outlook.reason && <p className="pt-1 text-xs" style={{ color: 'var(--subtle)' }}>{outlook.reason}</p>}
              </div>

              {protectedOffer && (
                <div className="rounded-2xl border p-4" style={{ background: 'rgba(141,216,159,0.08)', borderColor: 'rgba(141,216,159,0.4)' }} data-testid="hold-notice">
                  <p className="flex items-center gap-2 text-sm font-semibold" style={{ color: 'var(--success)' }}>
                    <ShieldCheck className="size-4" /> Buyer protection
                  </p>
                  <p className="mt-1 text-pretty text-sm" style={{ color: 'var(--muted)' }}>
                    Your money is held for {windowText}. Confirm when it arrives, or dispute. If you do nothing, the seller is paid when the window ends.
                  </p>
                </div>
              )}
              {buyerIsArbiter && <ErrorNote>You are this campaign&apos;s arbiter, so you cannot buy from it.</ErrorNote>}
              {endedReason && <ErrorNote>{endedReason}</ErrorNote>}
              {gate.isConnected && !endedReason && insufficient && haveBalance !== undefined && (
                <ErrorNote>Insufficient USDC. You have {fmtUsdc(haveBalance)} and need {fmtUsdc(price)}. Use Get test USDC in the Arc Studio sidebar.</ErrorNote>
              )}

              <ol className="space-y-3">
                <Step index={1} title="Allow USDC" status={approveStatus} detail={needsApproval ? `Lets Plug take ${fmtUsdc(price)}` : 'Allowed'} />
                <Step index={2} title="Buy" status={buyStatus} detail="Pays the seller and the agent in one transaction" />
              </ol>
              {action}
              <TxNotice state={approveTx.state} />
              <TxNotice state={buyTx.state} />
            </div>
          )}
        </section>
      </div>
    </Page>
  )
}
