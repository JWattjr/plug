import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import type { Log, PublicClient } from 'viem'
import { parseEventLogs } from 'viem'
import { usePublicClient } from 'wagmi'
import { plugAbi } from '@/lib/plugAbi'
import { STATUS, type Order } from '@/lib/orders'
import { sameAddress } from '@/lib/money'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'
import { PLUG_QUERY_KEY } from '@/hooks/useCampaigns'

/** Every protected order, read straight from the contract (prototype scale). */
export function useOrders() {
  const client = usePublicClient({ chainId: PLUG.chainId })
  const query = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'orders', PLUG.address],
    enabled: PLUG_CONFIGURED && Boolean(client),
    refetchInterval: 8_000,
    queryFn: async (): Promise<Order[]> => {
      if (!client || !PLUG.address) return []
      const address = PLUG.address
      const count = await client.readContract({ address, abi: plugAbi, functionName: 'orderCount' })
      const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i))
      const rows = await Promise.all(ids.map((id) => client.readContract({ address, abi: plugAbi, functionName: 'getOrder', args: [id] })))
      const owed = await Promise.all(
        rows.map((row, i) =>
          row.status === STATUS.Refunded
            ? client.readContract({ address, abi: plugAbi, functionName: 'refundOwedOf', args: [ids[i]] })
            : Promise.resolve(0n),
        ),
      )
      return rows.map((row, i) => ({ id: ids[i], ...row, owed: owed[i] })).reverse()
    },
  })
  const orders = useMemo(() => query.data ?? [], [query.data])
  return { orders, isLoading: query.isLoading, error: query.error }
}

export function useOrdersOf(filter: (order: Order) => boolean) {
  const { orders, isLoading, error } = useOrders()
  const mine = useMemo(() => orders.filter(filter), [orders, filter])
  return { orders: mine, isLoading, error }
}

export const isBuyer = (address: string | undefined) => (order: Order) => sameAddress(order.buyer, address)

/** Scan a block range for every event of the contract, halving the range if the RPC refuses a wide query. */
async function scanRaw(client: PublicClient, from: bigint, to: bigint): Promise<Log[]> {
  try {
    return await client.getLogs({ address: PLUG.address!, fromBlock: from, toBlock: to })
  } catch (error) {
    if (to - from < 2_000n) throw error
    const mid = from + (to - from) / 2n
    const left = await scanRaw(client, from, mid)
    const right = await scanRaw(client, mid + 1n, to)
    return [...left, ...right]
  }
}

function decode(logs: Log[]) {
  return parseEventLogs({ abi: plugAbi, logs })
}

export type PlugLog = ReturnType<typeof decode>[number]

/** Every contract event since the deploy block, oldest first. One shared read feeds the feed, earnings and order timelines. */
export function usePlugLogs() {
  const client = usePublicClient({ chainId: PLUG.chainId })
  const query = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'logs', PLUG.address],
    enabled: PLUG_CONFIGURED && Boolean(client) && PLUG.deployBlock !== undefined,
    refetchInterval: 12_000,
    queryFn: async (): Promise<PlugLog[]> => {
      const head = await client!.getBlockNumber()
      const raw = await scanRaw(client as PublicClient, PLUG.deployBlock!, head)
      return decode(raw)
    },
  })
  const logs = useMemo(() => query.data ?? [], [query.data])
  return { logs, isLoading: query.isLoading, error: query.error }
}

/** Events about one order, oldest first. */
export function eventsForOrder(logs: readonly PlugLog[], orderId: bigint): PlugLog[] {
  return logs.filter((log) => 'orderId' in log.args && (log.args as { orderId?: bigint }).orderId === orderId)
}

/** The buyer's dispute reason, from the OrderDisputed event. */
export function disputeReason(logs: readonly PlugLog[], orderId: bigint): string | undefined {
  for (const log of logs) {
    if (log.eventName === 'OrderDisputed' && log.args.orderId === orderId) return log.args.reason
  }
  return undefined
}

/** Commission actually delivered on a released order, from the OrderReleased event. */
export function deliveredCommission(logs: readonly PlugLog[], orderId: bigint): bigint | undefined {
  for (const log of logs) {
    if (log.eventName === 'OrderReleased' && log.args.orderId === orderId) return log.args.commissionDelivered
  }
  return undefined
}
