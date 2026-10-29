import type { PlugLog } from '@/hooks/useOrders'
import { fmtBps, fmtUsdc, shortAddress } from '@/lib/money'

export interface ActivityItem {
  key: string
  title: string
  detail: string
  /** Path inside the app, when there is a natural page to open. */
  href?: string
  tone: 'neutral' | 'good' | 'bad' | 'agent'
  txHash: `0x${string}`
  blockNumber: bigint
}

/** Turn a decoded contract event into one line of the activity feed. */
export function describeLog(log: PlugLog): ActivityItem | undefined {
  const base = { key: `${log.transactionHash}-${log.logIndex}`, txHash: log.transactionHash, blockNumber: log.blockNumber }
  switch (log.eventName) {
    case 'CampaignCreated': {
      const a = log.args
      const protectedText = a.protectionWindow > 0n ? `, protected ${Number(a.protectionWindow) / 86_400} days` : ''
      return { ...base, title: `Campaign #${a.id.toString()} created`, detail: `${fmtUsdc(a.price)} at ${fmtBps(a.commissionBps)} commission, budget ${fmtUsdc(a.budget)}${protectedText}`, href: `/checkout/${a.id.toString()}`, tone: 'neutral' }
    }
    case 'Purchase': {
      const a = log.args
      return { ...base, title: `Instant sale on campaign #${a.id.toString()}`, detail: `${fmtUsdc(a.price)}, ${a.commission > 0n ? `agent ${shortAddress(a.referrer)} earned ${fmtUsdc(a.commission)}` : 'no commission'}`, href: `/checkout/${a.id.toString()}`, tone: 'good' }
    }
    case 'OrderPlaced': {
      const a = log.args
      return { ...base, title: `Order #${a.orderId.toString()} placed`, detail: `${fmtUsdc(a.price)} held in escrow, ${fmtUsdc(a.commission)} commission reserved`, href: `/orders/${a.orderId.toString()}`, tone: 'agent' }
    }
    case 'OrderReleased': {
      const a = log.args
      return { ...base, title: `Order #${a.orderId.toString()} released`, detail: `Seller paid ${fmtUsdc(a.price)}, agent earned ${fmtUsdc(a.commissionDelivered)}`, href: `/orders/${a.orderId.toString()}`, tone: 'good' }
    }
    case 'OrderDisputed':
      return { ...base, title: `Order #${log.args.orderId.toString()} disputed`, detail: log.args.reason ? `"${log.args.reason.slice(0, 90)}"` : 'No reason given', href: `/orders/${log.args.orderId.toString()}`, tone: 'bad' }
    case 'OrderContested':
      return { ...base, title: `Order #${log.args.orderId.toString()} sent to the arbiter`, detail: 'The seller contested the dispute', href: `/orders/${log.args.orderId.toString()}`, tone: 'bad' }
    case 'OrderResolved':
      return { ...base, title: `Order #${log.args.orderId.toString()} decided by the arbiter`, detail: log.args.refundBuyer ? 'Buyer refunded' : 'Released to the seller', href: `/orders/${log.args.orderId.toString()}`, tone: 'neutral' }
    case 'OrderRefunded':
      return { ...base, title: `Order #${log.args.orderId.toString()} refunded`, detail: `${fmtUsdc(log.args.price)} back to the buyer, no commission paid`, href: `/orders/${log.args.orderId.toString()}`, tone: 'bad' }
    case 'RefundOwed':
      return { ...base, title: `Refund owed on order #${log.args.orderId.toString()}`, detail: `${fmtUsdc(log.args.amount)} waits for ${shortAddress(log.args.buyer)} to claim`, href: `/orders/${log.args.orderId.toString()}`, tone: 'bad' }
    case 'OwedRefundPaid':
      return { ...base, title: `Owed refund claimed on order #${log.args.orderId.toString()}`, detail: `${fmtUsdc(log.args.amount)} paid to ${shortAddress(log.args.buyer)}`, href: `/orders/${log.args.orderId.toString()}`, tone: 'good' }
    case 'CampaignEnded':
      return { ...base, title: `Campaign #${log.args.id.toString()} ended`, detail: `${fmtUsdc(log.args.refund)} unspent budget returned`, href: `/checkout/${log.args.id.toString()}`, tone: 'neutral' }
    case 'ToppedUp':
      return { ...base, title: `Campaign #${log.args.id.toString()} topped up`, detail: `+${fmtUsdc(log.args.amount)} budget`, href: `/checkout/${log.args.id.toString()}`, tone: 'neutral' }
    case 'ClosedBudgetWithdrawn':
      return { ...base, title: `Closed campaign #${log.args.id.toString()} budget withdrawn`, detail: fmtUsdc(log.args.amount), tone: 'neutral' }
    default:
      return undefined
  }
}
