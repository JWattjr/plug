import { useQuery } from '@tanstack/react-query'
import { createPublicClient, erc20Abi, type PublicClient, type Transport } from 'viem'
import { useAccount, usePublicClient } from 'wagmi'
import { readAllowanceResilient, type AllowanceReading, type ReadOnlyProvider } from '@/lib/allowance'
import { rpcHost, rpcTransport } from '@/lib/rpc'
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
 * Public-endpoint-only transport for the allowance read. Its two routes (batched, direct) must stay
 * on the public endpoints so a failure there is reported as such; the wallet route is explicit and
 * labelled separately. Tests swap in a fake transport.
 */
export const allowanceTransports = { http: (): Transport => rpcTransport(PLUG.rpcUrls) }

let batchedClient: PublicClient | undefined
let directClient: PublicClient | undefined
function getBatchedClient(): PublicClient {
  batchedClient ??= createPublicClient({ chain: PLUG.chain, transport: allowanceTransports.http(), batch: { multicall: true } }) as PublicClient
  return batchedClient
}
function getDirectClient(): PublicClient {
  // No multicall batching: a single eth_call to the USDC contract.
  directClient ??= createPublicClient({ chain: PLUG.chain, transport: allowanceTransports.http() }) as PublicClient
  return directClient
}

/** Test hook: forget cached clients after swapping the transport. */
export function resetAllowanceClients(): void {
  batchedClient = undefined
  directClient = undefined
}

/**
 * How much USDC `owner` has allowed Plug to pull.
 *
 * `data` is undefined until a read succeeds. Callers must treat undefined as unknown,
 * never as zero (see `resolveApprovalGate`). On failure `error` is an AllowanceReadError
 * holding every attempt, so the screen can show the real cause.
 */
export function useUsdcAllowance(owner?: `0x${string}`) {
  const { connector } = useAccount()
  return useQuery<AllowanceReading>({
    queryKey: usdcAllowanceKey(owner, PLUG.address),
    enabled: Boolean(owner && PLUG.usdcAddress && PLUG.address),
    refetchInterval: 8_000,
    refetchOnWindowFocus: 'always',
    refetchOnMount: 'always',
    // Each attempt already walks three read paths over several endpoints.
    retry: 1,
    retryDelay: 1_500,
    queryFn: () => {
      const token = PLUG.usdcAddress!
      const spender = PLUG.address!
      return readAllowanceResilient({
        chainId: PLUG.chainId,
        token,
        owner: owner!,
        spender,
        rpcHosts: PLUG.rpcUrls.map(rpcHost),
        readBatched: () => readUsdcAllowance(getBatchedClient(), token, owner!, spender),
        readDirect: () => readUsdcAllowance(getDirectClient(), token, owner!, spender),
        getWalletProvider: async () => (await connector?.getProvider?.()) as ReadOnlyProvider | undefined,
      })
    },
  })
}
