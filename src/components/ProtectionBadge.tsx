import { ExternalLink, ShieldCheck, Zap } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { isProtected, type Campaign } from '@/lib/campaigns'
import { shortAddress } from '@/lib/money'
import { fmtWindow } from '@/lib/time'
import { PLUG } from '@/plug.config'

interface Props {
  campaign: Campaign
  /** Show the arbiter address with its explorer link. */
  showArbiter?: boolean
  className?: string
}

/** "Protected · 7-day window · arbiter 0x…" or "Instant settlement". */
export function ProtectionBadge({ campaign, showArbiter = true, className = '' }: Props) {
  if (!isProtected(campaign)) {
    return (
      <span className={`chip ${className}`} data-testid="instant-badge">
        <Zap className="size-3" /> Instant settlement
      </span>
    )
  }
  return (
    <span
      className={`inline-flex flex-wrap items-center gap-x-1.5 gap-y-0.5 rounded-full border px-2.5 py-1 text-xs font-semibold ${className}`}
      style={{ background: 'rgba(141,216,159,0.10)', borderColor: 'rgba(141,216,159,0.4)', color: 'var(--success)' }}
      data-testid="protected-badge"
    >
      <ShieldCheck className="size-3.5" />
      <span>Protected · {fmtWindow(campaign.protectionWindow)} window</span>
      {showArbiter && (
        <>
          <span aria-hidden>·</span>
          <a
            href={buildAddressExplorerUrl(PLUG.chainId, campaign.arbiter)}
            target="_blank"
            rel="noreferrer"
            className="mono inline-flex items-center gap-0.5 underline-offset-2 hover:underline"
            onClick={(e) => e.stopPropagation()}
          >
            arbiter {shortAddress(campaign.arbiter)} <ExternalLink className="size-3" />
          </a>
        </>
      )}
    </span>
  )
}
