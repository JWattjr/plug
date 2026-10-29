import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import { ExternalLink } from 'lucide-react'
import { Skeleton } from '@/components/ui'
import { usePlugLogs } from '@/hooks/useOrders'
import { describeLog } from '@/lib/activity'
import { buildTxExplorerUrl } from '@/onchain-facts'
import { PLUG } from '@/plug.config'

const TONE: Record<string, string> = {
  neutral: 'var(--accent)',
  good: 'var(--success)',
  bad: 'var(--danger)',
  agent: 'var(--agent)',
}

/** Newest contract events first: campaigns, sales and every order event. */
export function ActivityFeed({ limit }: { limit?: number }) {
  const { logs, isLoading, error } = usePlugLogs()
  const items = useMemo(() => {
    const all = [...logs]
      .reverse()
      .map(describeLog)
      .filter((x): x is NonNullable<typeof x> => Boolean(x))
    return limit ? all.slice(0, limit) : all
  }, [logs, limit])

  if (isLoading) return <div className="space-y-2">{[0, 1, 2].map((i) => <Skeleton key={i} className="h-14 !rounded-2xl" />)}</div>
  if (error) return <p className="text-sm" style={{ color: 'var(--danger)' }}>Could not read activity from the chain. Retrying.</p>
  if (items.length === 0) return <p className="text-sm" style={{ color: 'var(--subtle)' }}>No activity yet. Create a campaign to see events here.</p>

  return (
    <ul className="space-y-2" aria-label="Recent activity" data-testid="activity-feed">
      {items.map((item) => (
        <li key={item.key} className="card flex items-center justify-between gap-3 px-4 py-3" data-event={item.title}>
          <div className="flex min-w-0 items-start gap-3">
            <span className="mt-1.5 size-2 shrink-0 rounded-full" style={{ background: TONE[item.tone] }} />
            <div className="min-w-0">
              <div className="truncate text-sm font-semibold">
                {item.href ? <Link className="underline-offset-2 hover:underline" to={item.href}>{item.title}</Link> : item.title}
              </div>
              <div className="truncate text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>{item.detail}</div>
            </div>
          </div>
          <a
            className="inline-flex shrink-0 items-center gap-1 text-xs font-semibold"
            style={{ color: 'var(--accent)' }}
            href={buildTxExplorerUrl(PLUG.chainId, item.txHash)}
            target="_blank"
            rel="noreferrer"
            aria-label="View transaction"
          >
            Tx <ExternalLink className="size-3" />
          </a>
        </li>
      ))}
    </ul>
  )
}
