import { useEffect } from 'react'
import { useQuery } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import { setClockOffset } from '@/lib/time'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'

/** Keeps the app's clock aligned with the chain's latest block time. Mount once. */
export function useChainClock(): void {
  const client = usePublicClient({ chainId: PLUG.chainId })
  const { data } = useQuery({
    queryKey: ['plug', 'chain-clock', PLUG.chainId],
    enabled: PLUG_CONFIGURED && Boolean(client),
    refetchInterval: 10_000,
    queryFn: async () => {
      const block = await client!.getBlock()
      return Number(block.timestamp) - Math.floor(Date.now() / 1000)
    },
  })
  useEffect(() => {
    if (data !== undefined) setClockOffset(data)
  }, [data])
}
