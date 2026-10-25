import { useCallback, useEffect, useMemo, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import { plugAbi } from '@/lib/plugAbi'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'
import { nowSeconds } from '@/lib/time'
import { isLive, type Campaign } from '@/lib/campaigns'

export const PLUG_QUERY_KEY = ['plug'] as const

/** Ticks once a second so countdowns and "ended" states stay honest. */
export function useNow(): number {
  const [now, setNow] = useState(nowSeconds())
  useEffect(() => {
    const timer = setInterval(() => setNow(nowSeconds()), 1000)
    return () => clearInterval(timer)
  }, [])
  return now
}

/** Invalidate every Plug read after a transaction lands. */
export function useRefreshPlug(): () => Promise<void> {
  const queryClient = useQueryClient()
  return useCallback(() => queryClient.invalidateQueries({ queryKey: PLUG_QUERY_KEY }), [queryClient])
}

/** All campaigns, read straight from the contract. Newest first. */
export function useCampaigns() {
  const client = usePublicClient({ chainId: PLUG.chainId })

  const query = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'campaigns', PLUG.address],
    enabled: PLUG_CONFIGURED && Boolean(client),
    refetchInterval: 10_000,
    queryFn: async (): Promise<Campaign[]> => {
      if (!client || !PLUG.address) return []
      const count = await client.readContract({ address: PLUG.address, abi: plugAbi, functionName: 'campaignCount' })
      const ids = Array.from({ length: Number(count) }, (_, i) => BigInt(i))
      const rows = await Promise.all(
        ids.map((id) => client.readContract({ address: PLUG.address as `0x${string}`, abi: plugAbi, functionName: 'getCampaign', args: [id] })),
      )
      return rows.map((row, i) => ({ id: ids[i], ...row })).reverse()
    },
  })

  const campaigns = useMemo(() => query.data ?? [], [query.data])
  return { campaigns, isLoading: query.isLoading, error: query.error, refetch: query.refetch }
}

/** Active, unexpired campaigns. */
export function useLiveOffers() {
  const { campaigns, isLoading, error } = useCampaigns()
  const now = useNow()
  const offers = useMemo(() => campaigns.filter((c) => isLive(c, now)), [campaigns, now])
  return { offers, isLoading, error, now }
}

/** Totals across every campaign, computed from chain state. */
export function useStats() {
  const { campaigns, isLoading, error } = useCampaigns()
  return useMemo(() => {
    let sales = 0n
    let commissionPaid = 0n
    let volume = 0n
    for (const c of campaigns) {
      sales += c.sales
      commissionPaid += c.commissionPaid
      volume += c.sales * c.price
    }
    return { campaigns: campaigns.length, sales, commissionPaid, volume, isLoading, error }
  }, [campaigns, isLoading, error])
}
