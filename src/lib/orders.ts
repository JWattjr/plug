import type { Campaign } from '@/lib/campaigns'

/** Mirrors the contract's Status enum order. */
export const STATUS = { Pending: 0, Disputed: 1, Contested: 2, Released: 3, Refunded: 4 } as const
export type OrderStatusName = keyof typeof STATUS

export const STATUS_NAMES: OrderStatusName[] = ['Pending', 'Disputed', 'Contested', 'Released', 'Refunded']

/** An order as stored by the contract, with its id and any refund still owed. */
export interface Order {
  id: bigint
  campaignId: bigint
  buyer: `0x${string}`
  referrer: `0x${string}`
  price: bigint
  commission: bigint
  releaseAt: bigint
  disputeDeadline: bigint
  status: number
  /** Price owed to the buyer after a refund the buyer could not receive. */
  owed: bigint
}

export const statusName = (order: Pick<Order, 'status'>): OrderStatusName => STATUS_NAMES[order.status] ?? 'Pending'

export const isOpen = (order: Order): boolean => order.status <= STATUS.Contested

/** Three days to respond to a dispute, fourteen for the arbiter. Mirrors the contract. */
export const DISPUTE_PERIOD_SECONDS = 3 * 86_400
export const ARBITER_TIMEOUT_SECONDS = 14 * 86_400

export const WINDOW_CHOICES_DAYS = [3, 7, 14, 30] as const

export interface TimelineStep {
  label: string
  state: 'done' | 'current' | 'todo' | 'bad'
  detail?: string
}

/** Steps for the buyer's status timeline. */
export function timelineFor(order: Order, now: number): TimelineStep[] {
  const s = order.status
  const released = s === STATUS.Released
  const refunded = s === STATUS.Refunded
  const windowOver = now >= Number(order.releaseAt)
  const wasDisputed = s === STATUS.Disputed || s === STATUS.Contested || (refunded && order.disputeDeadline > 0n)

  if (wasDisputed) {
    return [
      { label: 'Paid', state: 'done' },
      { label: 'Held', state: 'done' },
      { label: 'Disputed', state: s === STATUS.Disputed ? 'current' : 'done' },
      { label: 'Contested', state: s === STATUS.Contested ? 'current' : 'todo', detail: s === STATUS.Disputed ? 'if the seller escalates' : undefined },
      { label: refunded ? 'Refunded' : 'Resolved', state: refunded ? 'done' : 'todo' },
    ]
  }
  return [
    { label: 'Paid', state: 'done' },
    { label: 'Held', state: released || refunded ? 'done' : windowOver ? 'done' : 'current' },
    refunded
      ? { label: 'Refunded', state: 'bad' }
      : { label: 'Released', state: released ? 'done' : 'todo', detail: released ? undefined : windowOver ? 'ready to release' : undefined },
  ]
}

export function campaignOf(campaigns: readonly Campaign[], order: Order): Campaign | undefined {
  return campaigns.find((c) => c.id === order.campaignId)
}
