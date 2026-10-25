import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { getAbiItem, isAddress, type PublicClient } from 'viem'
import { usePublicClient } from 'wagmi'
import { Bot, ExternalLink, Search } from 'lucide-react'
import { EmptyState, ErrorNote, Page, PageTitle, Skeleton, TxLink } from '@/components/ui'
import { PLUG_QUERY_KEY } from '@/hooks/useCampaigns'
import { fmtUsdc, shortAddress } from '@/lib/money'
import { fmtDate } from '@/lib/time'
import { plugAbi } from '@/lib/plugAbi'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'
import { buildAddressExplorerUrl } from '@/onchain-facts'

const purchaseEvent = getAbiItem({ abi: plugAbi, name: 'Purchase' })

interface PurchaseRow {
  id: bigint
  buyer: `0x${string}`
  price: bigint
  commission: bigint
  blockNumber: bigint
  txHash: `0x${string}`
  timestamp?: number
}

/** Scan a block range for Purchase events, halving the range if the RPC refuses a wide query. */
async function scan(client: PublicClient, referrer: `0x${string}`, from: bigint, to: bigint): Promise<PurchaseRow[]> {
  try {
    const logs = await client.getLogs({ address: PLUG.address!, event: purchaseEvent, args: { referrer }, fromBlock: from, toBlock: to })
    return logs.map((log) => ({
      id: log.args.id!,
      buyer: log.args.buyer!,
      price: log.args.price!,
      commission: log.args.commission!,
      blockNumber: log.blockNumber,
      txHash: log.transactionHash,
    }))
  } catch (error) {
    if (to - from < 2_000n) throw error
    const mid = from + (to - from) / 2n
    const left = await scan(client, referrer, from, mid)
    const right = await scan(client, referrer, mid + 1n, to)
    return [...left, ...right]
  }
}

async function loadPurchases(client: PublicClient, referrer: `0x${string}`): Promise<PurchaseRow[]> {
  const head = await client.getBlockNumber()
  const found = await scan(client, referrer, PLUG.deployBlock!, head)
  const rows: PurchaseRow[] = [...found].sort((a, b) => (a.blockNumber < b.blockNumber ? 1 : a.blockNumber > b.blockNumber ? -1 : 0))

  const newest = rows.slice(0, 25)
  const blocks = Array.from(new Set(newest.map((r) => r.blockNumber)))
  const stamps = new Map<bigint, number>()
  await Promise.all(
    blocks.map(async (blockNumber) => {
      try {
        const block = await client.getBlock({ blockNumber })
        stamps.set(blockNumber, Number(block.timestamp))
      } catch {
        // A missing timestamp is cosmetic. The row still shows its block.
      }
    }),
  )
  return rows.map((r) => ({ ...r, timestamp: stamps.get(r.blockNumber) }))
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

  const earned = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'earnings', PLUG.address, agent],
    enabled: Boolean(agent && client && PLUG_CONFIGURED),
    refetchInterval: 10_000,
    queryFn: () => client!.readContract({ address: PLUG.address!, abi: plugAbi, functionName: 'referrerEarnings', args: [agent!] }),
  })

  const history = useQuery({
    queryKey: [...PLUG_QUERY_KEY, 'purchases', PLUG.address, agent],
    enabled: Boolean(agent && client && PLUG_CONFIGURED),
    refetchInterval: 15_000,
    queryFn: () => loadPurchases(client as PublicClient, agent!),
  })

  const rows = history.data ?? []
  const isDemo = agent && PLUG.demoAgent && agent.toLowerCase() === PLUG.demoAgent.toLowerCase()

  return (
    <Page>
      <PageTitle title="Agent earnings" subtitle="Commission an agent address has earned, with every sale it referred." />

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
            </div>
          </div>

          <h2 className="display mb-3 text-xl font-semibold">Referred sales</h2>
          {history.error && <ErrorNote>Could not load this address&apos;s sales from the chain. Retrying.</ErrorNote>}
          {history.isLoading ? (
            <div className="space-y-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-16 !rounded-2xl" />)}</div>
          ) : rows.length === 0 && !history.error ? (
            <EmptyState
              title="No referred sales yet"
              body="When a buyer completes a purchase through a link with this address as the referrer, it shows up here."
              action={<Link to="/agent" className="btn btn-ghost">Try the demo agent</Link>}
            />
          ) : (
            <ul className="space-y-2">
              {rows.map((r) => (
                <li key={`${r.txHash}-${r.id}`} className="card flex flex-wrap items-center justify-between gap-3 px-5 py-4">
                  <div>
                    <div className="text-sm font-semibold">
                      Campaign #{r.id.toString()} <span className="font-normal tabular-nums" style={{ color: 'var(--subtle)' }}>· sale of {fmtUsdc(r.price)}</span>
                    </div>
                    <div className="mt-0.5 text-xs" style={{ color: 'var(--subtle)' }}>
                      Buyer <span className="mono">{shortAddress(r.buyer)}</span>
                      {r.timestamp ? ` · ${fmtDate(r.timestamp)}` : ` · block ${r.blockNumber.toString()}`}
                    </div>
                  </div>
                  <div className="flex items-center gap-4">
                    <span className="display text-lg font-bold tabular-nums" style={{ color: r.commission > 0n ? 'var(--agent)' : 'var(--subtle)' }}>
                      {r.commission > 0n ? `+${fmtUsdc(r.commission)}` : 'No commission'}
                    </span>
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
