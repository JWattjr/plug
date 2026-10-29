import { useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { isAddress } from 'viem'
import { usePublicClient } from 'wagmi'
import { Bot, ExternalLink, Search } from 'lucide-react'
import { EmptyState, ErrorNote, Page, PageTitle, Skeleton, TxLink } from '@/components/ui'
import { PLUG_QUERY_KEY } from '@/hooks/useCampaigns'
import { deliveredCommission, useOrders, usePlugLogs } from '@/hooks/useOrders'
import { fmtUsdc, sameAddress, shortAddress } from '@/lib/money'
import { plugAbi } from '@/lib/plugAbi'
import { STATUS, statusName } from '@/lib/orders'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'
import { buildAddressExplorerUrl } from '@/onchain-facts'

interface Row {
  key: string
  campaignId: bigint
  buyer: `0x${string}`
  price: bigint
  /** Text for the right-hand side. */
  amountText: string
  tone: 'earned' | 'pending' | 'none'
  note?: string
  blockNumber: bigint
  txHash: `0x${string}`
  orderId?: bigint
}

function Lookup() {
  const navigate = useNavigate()
  const [value, setValue] = useState('')
  const valid = isAddress(value.trim())
  return (
    <form
      className="flex gap-2"
      onSubmit={(e) => {
        e.preventDefault()
        if (valid) navigate(`/earnings/${value.trim()}`)
      }}
    >
      <input className="field mono !text-sm" placeholder="Look up another address (0x…)" aria-label="Agent address" value={value} onChange={(e) => setValue(e.target.value)} />
      <button className="btn btn-ghost" type="submit" disabled={!valid} aria-label="Look up"><Search className="size-4" /></button>
    </form>
  )
}

export default function Earnings() {
  const { address } = useParams()
  const valid = Boolean(address && isAddress(address))
  const agent = valid ? (address as `0x${string}`) : undefined
  const client = usePublicClient({ chainId: PLUG.chainId })
  const { logs, isLoading: loadingLogs, error: logsError } = usePlugLogs()
  const { orders } = useOrders()

  const earned = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'earnings', PLUG.address, agent],
    enabled: Boolean(agent && client && PLUG_CONFIGURED),
    refetchInterval: 10_000,
    queryFn: () => client!.readContract({ address: PLUG.address!, abi: plugAbi, functionName: 'referrerEarnings', args: [agent!] }),
  })

  const { rows, pendingTotal } = useMemo(() => {
    const out: Row[] = []
    let pending = 0n
    if (!agent) return { rows: out, pendingTotal: pending }
    for (const log of logs) {
      if (log.eventName === 'Purchase' && sameAddress(log.args.referrer, agent)) {
        out.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          campaignId: log.args.id,
          buyer: log.args.buyer,
          price: log.args.price,
          amountText: log.args.commission > 0n ? `+${fmtUsdc(log.args.commission)}` : 'No commission',
          tone: log.args.commission > 0n ? 'earned' : 'none',
          blockNumber: log.blockNumber,
          txHash: log.transactionHash,
        })
      }
      if (log.eventName === 'OrderPlaced' && sameAddress(log.args.referrer, agent)) {
        const order = orders.find((o) => o.id === log.args.orderId)
        let row: Pick<Row, 'amountText' | 'tone' | 'note'>
        if (!order || order.status <= STATUS.Contested) {
          if (log.args.commission > 0n) pending += log.args.commission
          row = log.args.commission > 0n
            ? { amountText: `${fmtUsdc(log.args.commission)} pending`, tone: 'pending', note: `Order ${order ? statusName(order).toLowerCase() : 'pending'}: paid only if the sale sticks` }
            : { amountText: 'No commission', tone: 'none' }
        } else if (order.status === STATUS.Released) {
          const delivered = deliveredCommission(logs, order.id) ?? 0n
          row = delivered > 0n ? { amountText: `+${fmtUsdc(delivered)}`, tone: 'earned', note: 'Order released' } : { amountText: 'No commission', tone: 'none', note: 'Order released' }
        } else {
          row = { amountText: 'No commission', tone: 'none', note: 'Order refunded: a refunded sale pays nothing' }
        }
        out.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          campaignId: log.args.campaignId,
          buyer: log.args.buyer,
          price: log.args.price,
          blockNumber: log.blockNumber,
          txHash: log.transactionHash,
          orderId: log.args.orderId,
          ...row,
        })
      }
    }
    out.sort((a, b) => (a.blockNumber < b.blockNumber ? 1 : a.blockNumber > b.blockNumber ? -1 : 0))
    return { rows: out, pendingTotal: pending }
  }, [logs, orders, agent])

  const isDemo = agent && PLUG.demoAgent && agent.toLowerCase() === PLUG.demoAgent.toLowerCase()
  const colorFor = (tone: Row['tone']) => (tone === 'earned' ? 'var(--agent)' : tone === 'pending' ? 'var(--muted)' : 'var(--subtle)')

  return (
    <Page>
      <PageTitle title="Agent earnings" subtitle="Commission an agent address has earned, with every sale it referred. Protected orders pay the agent only when they release." />

      <div className="mb-6 max-w-xl"><Lookup /></div>

      {!valid ? (
        <ErrorNote>That is not a valid address. Check it and try again.</ErrorNote>
      ) : (
        <>
          <div className="card mb-6 flex flex-col gap-4 p-6 sm:flex-row sm:items-center sm:justify-between sm:p-7">
            <div>
              <div className="label flex items-center gap-1.5"><Bot className="size-3.5" /> {isDemo ? 'Demo agent' : 'Agent'}</div>
              <a className="mono inline-flex items-center gap-1 break-all text-xs underline-offset-2 hover:underline" style={{ color: 'var(--muted)' }} href={buildAddressExplorerUrl(PLUG.chainId, agent!)} target="_blank" rel="noreferrer">
                {agent} <ExternalLink className="size-3 shrink-0" />
              </a>
            </div>
            <div className="sm:text-right">
              <div className="label">Total earned</div>
              {earned.isLoading ? (
                <Skeleton className="h-10 w-40" />
              ) : earned.error ? (
                <span className="text-sm" style={{ color: 'var(--danger)' }}>Could not read earnings</span>
              ) : (
                <div className="display text-4xl font-bold tabular-nums" style={{ color: 'var(--agent)' }} data-testid="total-earned">{fmtUsdc(earned.data ?? 0n)}</div>
              )}
              {pendingTotal > 0n && <div className="mt-1 text-xs tabular-nums" style={{ color: 'var(--subtle)' }} data-testid="pending-total">{fmtUsdc(pendingTotal)} pending in open orders</div>}
            </div>
          </div>

          <h2 className="display mb-3 text-xl font-semibold">Referred sales</h2>
          {logsError && <ErrorNote>Could not load this address&apos;s sales from the chain. Retrying.</ErrorNote>}
          {loadingLogs ? (
            <div className="space-y-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16 !rounded-2xl" />)}</div>
          ) : rows.length === 0 && !logsError ? (
            <EmptyState
              title="No referred sales yet"
              body="When a buyer completes a purchase through a link with this address as the referrer, it shows up here."
              action={<Link to="/agent" className="btn btn-ghost">Try the demo agent</Link>}
            />
          ) : (
            <ul className="space-y-2">
              {rows.map((r) => (
                <li key={r.key} className="card flex flex-wrap items-center justify-between gap-3 px-5 py-4" data-tone={r.tone}>
                  <div>
                    <div className="text-sm font-semibold">
                      Campaign #{r.campaignId.toString()} <span className="font-normal tabular-nums" style={{ color: 'var(--subtle)' }}>· sale of {fmtUsdc(r.price)}</span>
                    </div>
                    <div className="mt-0.5 text-xs" style={{ color: 'var(--subtle)' }}>
                      Buyer <span className="mono">{shortAddress(r.buyer)}</span> · block {r.blockNumber.toString()}
                      {r.orderId !== undefined && <> · <Link className="underline underline-offset-2" to={`/orders/${r.orderId.toString()}`}>order #{r.orderId.toString()}</Link></>}
                      {r.note && <> · {r.note}</>}
                    </div>
                  </div>
                  <div className="flex items-center gap-4">
                    <span className="display text-lg font-bold tabular-nums" style={{ color: colorFor(r.tone) }}>{r.amountText}</span>
                    <TxLink hash={r.txHash} label="Tx" />
                  </div>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </Page>
  )
}
