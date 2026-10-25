import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ArrowUpRight, Clock, Percent, Wallet } from 'lucide-react'
import { SponsoredBadge } from '@/components/ui'
import { canPayCommission, commissionPerSale, type Campaign } from '@/lib/campaigns'
import { fmtBps, fmtNumber, shortAddress } from '@/lib/money'
import { fmtTimeLeft } from '@/lib/time'

interface Props {
  campaign: Campaign
  now: number
  index?: number
}

export function OfferCard({ campaign, now, index = 0 }: Props) {
  const payable = canPayCommission(campaign)
  return (
    <motion.article
      initial={{ opacity: 0, y: 14 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: Math.min(index, 8) * 0.05, duration: 0.4, ease: [0.22, 1, 0.36, 1] }}
      className="card card-lift flex flex-col gap-4 p-5"
      aria-label={`Sponsored offer: ${campaign.title}`}
    >
      <div className="flex items-start justify-between gap-3">
        <SponsoredBadge />
        <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>#{campaign.id.toString()}</span>
      </div>

      <div>
        <h3 className="display text-balance text-xl font-semibold leading-tight">{campaign.title || 'Untitled offer'}</h3>
        <p className="mt-1 truncate text-xs" style={{ color: 'var(--subtle)' }}>
          by {shortAddress(campaign.advertiser)}
        </p>
      </div>

      <div className="flex items-baseline gap-1.5">
        <span className="display text-3xl font-bold tabular-nums">{fmtNumber(campaign.price)}</span>
        <span className="text-sm" style={{ color: 'var(--subtle)' }}>USDC</span>
      </div>

      <dl className="grid grid-cols-3 gap-2 text-xs">
        <div className="inner p-2.5">
          <dt className="mb-1 flex items-center gap-1" style={{ color: 'var(--subtle)' }}><Percent className="size-3" /> Commission</dt>
          <dd className="font-semibold tabular-nums" style={{ color: 'var(--agent)' }}>{fmtBps(campaign.commissionBps)}</dd>
        </div>
        <div className="inner p-2.5">
          <dt className="mb-1 flex items-center gap-1" style={{ color: 'var(--subtle)' }}><Wallet className="size-3" /> Budget left</dt>
          <dd className="font-semibold tabular-nums">{fmtNumber(campaign.budgetRemaining)}</dd>
        </div>
        <div className="inner p-2.5">
          <dt className="mb-1 flex items-center gap-1" style={{ color: 'var(--subtle)' }}><Clock className="size-3" /> Ends in</dt>
          <dd className="font-semibold tabular-nums">{fmtTimeLeft(campaign.endTime, now)}</dd>
        </div>
      </dl>

      {!payable && campaign.commissionBps > 0 && (
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>
          Budget is below one commission ({fmtNumber(commissionPerSale(campaign))} USDC), so new sales pay agents nothing.
        </p>
      )}

      <Link to={`/checkout/${campaign.id.toString()}`} className="btn btn-ghost mt-auto w-full">
        View offer <ArrowUpRight className="size-4" />
      </Link>
    </motion.article>
  )
}
