import { useQuery } from '@tanstack/react-query'
import { erc20Abi } from 'viem'
import { usePublicClient } from 'wagmi'
import { PLUG } from '@/plug.config'
import { PLUG_QUERY_KEY } from '@/hooks/useCampaigns'

/** ERC-20 USDC balance (6 decimals). On Arc this is the same pool as gas. */
export function useUsdcBalance(owner?: `0x${string}`) {
  const client = usePublicClient({ chainId: PLUG.chainId })
  return useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'usdc-balance', owner],
    enabled: Boolean(owner && client && PLUG.usdcAddress),
    refetchInterval: 8_000,
    queryFn: () =>
      client!.readContract({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'balanceOf', args: [owner!] }),
  })
}

/** How much USDC the connected wallet has allowed Plug to pull. */
export function useUsdcAllowance(owner?: `0x${string}`) {
  const client = usePublicClient({ chainId: PLUG.chainId })
  return useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'usdc-allowance', owner, PLUG.address],
    enabled: Boolean(owner && client && PLUG.usdcAddress && PLUG.address),
    refetchInterval: 8_000,
    queryFn: () =>
      client!.readContract({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'allowance', args: [owner!, PLUG.address!] }),
  })
}
