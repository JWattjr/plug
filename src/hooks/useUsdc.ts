import { useQuery } from '@tanstack/react-query'
import { erc20Abi } from 'viem'
import { usePublicClient } from 'wagmi'
import { PLUG } from '@/plug.config'
import { PLUG_QUERY_KEY } from '@/hooks/useCampaigns'

/** ERC-20 USDC balance (6 decimals). On Arc this is the same pool as gas. */
export function useUsdcBalance(owner?: `0x${string}`) {
  const client = usePublicClient({ chainId: PLUG.chainId })
  return useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'usdc-balance', PLUG.chainId, owner?.toLowerCase()],
    enabled: Boolean(owner && client && PLUG.usdcAddress),
    refetchInterval: 8_000,
    queryFn: () =>
      client!.readContract({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'balanceOf', args: [owner!] }),
  })
}

/** The minimal read surface the allowance query needs. Lets tests pass a mock client. */
export interface AllowanceReader {
  readContract: (args: {
    address: `0x${string}`
    abi: typeof erc20Abi
    functionName: 'allowance'
    args: readonly [`0x${string}`, `0x${string}`]
  }) => Promise<unknown>
}

/** Read allowance(owner, spender). Throws unless the node returned a real uint256. */
export async function readUsdcAllowance(
  client: AllowanceReader,
  token: `0x${string}`,
  owner: `0x${string}`,
  spender: `0x${string}`,
): Promise<bigint> {
  const value = await client.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [owner, spender] })
  if (typeof value !== 'bigint') throw new Error('Allowance read returned an unexpected value')
  return value
}

/** Cache key for one (chain, token, owner, spender) allowance. Never shared across accounts or networks. */
export function usdcAllowanceKey(owner?: string, spender?: string) {
  return [...PLUG_QUERY_KEY, 'usdc-allowance', PLUG.chainId, PLUG.usdcAddress?.toLowerCase(), owner?.toLowerCase(), spender?.toLowerCase()] as const
}

/**
 * How much USDC `owner` has allowed Plug to pull.
 *
 * `data` is undefined until a read succeeds. Callers must treat undefined as unknown,
 * never as zero (see `resolveApprovalGate`).
 */
export function useUsdcAllowance(owner?: `0x${string}`) {
  const client = usePublicClient({ chainId: PLUG.chainId })
  return useQuery({
    queryKey: usdcAllowanceKey(owner, PLUG.address),
    enabled: Boolean(owner && client && PLUG.usdcAddress && PLUG.address),
    refetchInterval: 8_000,
    refetchOnWindowFocus: 'always',
    refetchOnMount: 'always',
    retry: 3,
    queryFn: () => readUsdcAllowance(client as unknown as AllowanceReader, PLUG.usdcAddress!, owner!, PLUG.address!),
  })
}
