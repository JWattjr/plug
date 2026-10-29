import { useState } from 'react'
import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { Gavel, Hourglass } from 'lucide-react'
import type { Hash } from 'viem'
import { ErrorNote, Spinner, TxNotice } from '@/components/ui'
import { OrderTimeline } from '@/components/OrderTimeline'
import { useNow } from '@/hooks/useCampaigns'
import { deliveredCommission, disputeReason, type PlugLog } from '@/hooks/useOrders'
import { useTx } from '@/hooks/useTx'
import type { Campaign } from '@/lib/campaigns'
import { fmtUsdc, shortAddress } from '@/lib/money'
import { statusName, STATUS, timelineFor, type Order } from '@/lib/orders'
import { plugAbi } from '@/lib/plugAbi'
import { fmtDate, fmtTimeLeft } from '@/lib/time'
import { PLUG } from '@/plug.config'

export type OrderRole = 'buyer' | 'seller' | 'arbiter' | 'viewer'

interface Props {
  order: Order
  campaign?: Campaign
  logs: readonly PlugLog[]
  role: OrderRole
  /** Hide the status timeline (used in dense seller lists). */
  compact?: boolean
}

const MAX_REASON_BYTES = 256
const byteLength = (s: string) => new TextEncoder().encode(s).length

const STATUS_COLOR: Record<string, string> = {
  Pending: 'var(--agent)',
  Disputed: 'var(--danger)',
  Contested: 'var(--danger)',
  Released: 'var(--success)',
  Refunded: 'var(--subtle)',
}

export function OrderCard({ order, campaign, logs, role, compact }: Props) {
  const now = useNow()
  const tx = useTx()
  const [disputing, setDisputing] = useState(false)
  const [reason, setReason] = useState('')

  const status = statusName(order)
  const windowOver = now >= Number(order.releaseAt)
  const deadlinePassed = order.disputeDeadline > 0n && now >= Number(order.disputeDeadline)
  const reasonText = disputeReason(logs, order.id)
  const delivered = deliveredCommission(logs, order.id)

  function send(build: () => Promise<Hash>) {
    void tx.run(build).then(() => {
      setDisputing(false)
      setReason('')
    })
  }

  const base = { address: PLUG.address!, abi: plugAbi, chainId: PLUG.chainId } as const
  const id = order.id
  const call = (fn: 'confirm' | 'release' | 'refund' | 'contest' | 'claimRefund' | 'claimOwedRefund') => () => {
    switch (fn) {
      case 'confirm': return tx.writeContractAsync({ ...base, functionName: 'confirm', args: [id] })
      case 'release': return tx.writeContractAsync({ ...base, functionName: 'release', args: [id] })
      case 'refund': return tx.writeContractAsync({ ...base, functionName: 'refund', args: [id] })
      case 'contest': return tx.writeContractAsync({ ...base, functionName: 'contest', args: [id] })
      case 'claimRefund': return tx.writeContractAsync({ ...base, functionName: 'claimRefund', args: [id] })
      case 'claimOwedRefund': return tx.writeContractAsync({ ...base, functionName: 'claimOwedRefund', args: [id] })
    }
  }

  const buttons: React.ReactNode[] = []
  const btn = (key: string, label: string, onClick: () => void, kind: 'btn-primary' | 'btn-ghost' | 'btn-danger' = 'btn-ghost') =>
    buttons.push(
      <button key={key} className={`btn ${kind}`} disabled={tx.busy} onClick={onClick} data-testid={`action-${key}`}>
        {tx.busy && <Spinner />} {label}
      </button>,
    )

  if (role === 'buyer') {
    if (status === 'Pending' && !windowOver) {
      btn('confirm', 'Confirm it arrived', () => send(call('confirm')), 'btn-primary')
      btn('dispute', 'Dispute', () => setDisputing((v) => !v))
    }
    if (status === 'Pending' && windowOver) btn('release', 'Release now', () => send(call('release')), 'btn-primary')
    if (status === 'Disputed') {
      btn('confirm', 'Confirm it arrived', () => send(call('confirm')))
      if (deadlinePassed) btn('claimRefund', 'Claim refund', () => send(call('claimRefund')), 'btn-primary')
    }
    if (status === 'Contested' && deadlinePassed) btn('claimRefund', 'Claim refund', () => send(call('claimRefund')), 'btn-primary')
    if (status === 'Refunded' && order.owed > 0n) btn('claimOwedRefund', `Claim owed refund (${fmtUsdc(order.owed)})`, () => send(call('claimOwedRefund')), 'btn-primary')
  }
  if (role === 'viewer') {
    // Anyone may release a finished window or push an owed refund to its buyer.
    if (status === 'Pending' && windowOver) btn('release', 'Release to seller', () => send(call('release')), 'btn-primary')
    if (status === 'Refunded' && order.owed > 0n) btn('claimOwedRefund', 'Send owed refund to buyer', () => send(call('claimOwedRefund')))
  }
  if (role === 'seller') {
    if (status === 'Pending' && windowOver) btn('release', 'Release', () => send(call('release')), 'btn-primary')
    if (status === 'Disputed' && !deadlinePassed) btn('contest', 'Contest (send to arbiter)', () => send(call('contest')))
    if (status === 'Pending' || status === 'Disputed' || status === 'Contested') btn('refund', 'Refund buyer', () => send(call('refund')), 'btn-danger')
  }
  if (role === 'arbiter' && status === 'Contested' && !deadlinePassed) {
    btn(
      'refundBuyer',
      'Refund buyer',
      () => send(() => tx.writeContractAsync({ ...base, functionName: 'resolve', args: [id, true] })),
      'btn-danger',
    )
    btn(
      'releaseSeller',
      'Release to seller',
      () => send(() => tx.writeContractAsync({ ...base, functionName: 'resolve', args: [id, false] })),
      'btn-primary',
    )
  }

  // What is happening now, in words.
  let clock = ''
  if (status === 'Pending') {
    clock = windowOver ? 'The protection window is over. Anyone can release this order.' : `Releases to the seller in ${fmtTimeLeft(order.releaseAt, now)}`
  } else if (status === 'Disputed') {
    clock = deadlinePassed
      ? role === 'buyer' ? 'The seller did not respond in time. You can claim your refund.' : 'The response period is over. The buyer can claim a refund.'
      : role === 'seller' ? `Respond within ${fmtTimeLeft(order.disputeDeadline, now)}: refund, or contest to the arbiter` : `Seller has ${fmtTimeLeft(order.disputeDeadline, now)} to respond`
  } else if (status === 'Contested') {
    clock = deadlinePassed
      ? role === 'arbiter' ? 'The arbiter window closed. The buyer can claim a refund.' : 'The arbiter did not decide in time. The buyer can claim a refund.'
      : `Arbiter has ${fmtTimeLeft(order.disputeDeadline, now)} to decide`
  } else if (status === 'Refunded' && order.owed > 0n) {
    clock = 'Your refund could not be delivered to your wallet. Claim it once your address can receive USDC.'
  }

  const title = campaign?.title || `Campaign #${order.campaignId.toString()}`
  return (
    <motion.article layout initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="card card-lift space-y-4 p-5" data-testid={`order-${order.id.toString()}`} data-status={status}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link to={`/orders/${order.id.toString()}`} className="display text-lg font-semibold underline-offset-2 hover:underline">{title}</Link>
          <p className="mt-0.5 text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
            Order #{order.id.toString()} · {fmtUsdc(order.price)} · buyer <span className="mono">{shortAddress(order.buyer)}</span>
          </p>
        </div>
        <span className="chip" style={{ color: STATUS_COLOR[status] }} data-testid="order-status">{status}</span>
      </div>

      {!compact && <OrderTimeline steps={timelineFor(order, now)} />}

      {clock && (
        <p className="flex items-center gap-2 text-sm" style={{ color: 'var(--muted)' }} data-testid="order-clock">
          <Hourglass className="size-4 shrink-0" /> {clock}
        </p>
      )}

      <dl className="grid grid-cols-2 gap-2 text-xs sm:grid-cols-4">
        <div className="inner p-2.5"><dt className="label !mb-0.5">Held until</dt><dd className="tabular-nums">{fmtDate(order.releaseAt)}</dd></div>
        <div className="inner p-2.5"><dt className="label !mb-0.5">Agent</dt><dd className="mono">{order.referrer === '0x0000000000000000000000000000000000000000' ? 'none' : shortAddress(order.referrer)}</dd></div>
        <div className="inner p-2.5">
          <dt className="label !mb-0.5">{status === 'Released' ? 'Commission paid' : 'Commission'}</dt>
          <dd className="tabular-nums">{status === 'Released' ? fmtUsdc(delivered ?? 0n) : status === 'Refunded' ? 'none (refunded)' : fmtUsdc(order.commission)}</dd>
        </div>
        {order.disputeDeadline > 0n && status !== 'Released' && status !== 'Refunded' && (
          <div className="inner p-2.5"><dt className="label !mb-0.5">Deadline</dt><dd className="tabular-nums">{fmtDate(order.disputeDeadline)}</dd></div>
        )}
      </dl>

      {reasonText !== undefined && (status === 'Disputed' || status === 'Contested' || role === 'arbiter') && (
        <div className="inner p-3 text-sm" data-testid="dispute-reason">
          <div className="label flex items-center gap-1.5"><Gavel className="size-3" /> Buyer&apos;s reason</div>
          <p className="text-pretty" style={{ color: 'var(--muted)' }}>{reasonText || '(no reason given)'}</p>
        </div>
      )}

      {disputing && (
        <div className="inner space-y-3 p-4">
          <label className="label" htmlFor={`reason-${order.id.toString()}`}>What went wrong?</label>
          <textarea
            id={`reason-${order.id.toString()}`}
            className="field min-h-24"
            placeholder="Explain the problem. The seller and the arbiter will read this."
            value={reason}
            onChange={(e) => setReason(e.target.value)}
          />
          {byteLength(reason) > MAX_REASON_BYTES && <ErrorNote>Keep the reason under {MAX_REASON_BYTES} bytes.</ErrorNote>}
          <button
            className="btn btn-danger"
            disabled={tx.busy || !reason.trim() || byteLength(reason) > MAX_REASON_BYTES}
            data-testid="submit-dispute"
            onClick={() => send(() => tx.writeContractAsync({ ...base, functionName: 'dispute', args: [id, reason.trim()] }))}
          >
            {tx.busy && <Spinner />} Open dispute
          </button>
        </div>
      )}

      {buttons.length > 0 && <div className="flex flex-wrap gap-2">{buttons}</div>}
      <TxNotice state={tx.state} />
      {tx.state.status === 'success' && status !== 'Pending' && <p className="text-xs" style={{ color: 'var(--success)' }}>Done.</p>}
      {order.status === STATUS.Released && delivered === 0n && order.commission > 0n && (
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>The agent&apos;s commission could not be delivered and went back to the seller&apos;s budget.</p>
      )}
    </motion.article>
  )
}
