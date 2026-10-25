import { motion, useReducedMotion } from 'framer-motion'
import { ArrowDown, Bot, Store, User } from 'lucide-react'
import { fmtNumber } from '@/lib/money'

interface Props {
  /** Raw USDC the buyer paid. */
  price: bigint
  /** Raw USDC commission actually paid to the agent. */
  commission: bigint
  /** Why the agent earned nothing. Shown when commission is zero. */
  noCommissionReason?: string
  /** Label the figures as an example rather than a real sale. */
  example?: boolean
}

/**
 * The hero: one payment from the buyer splits into the seller's share and the
 * agent's commission. Bar widths are the real proportions of the real amounts.
 */
export function SplitVisual({ price, commission, noCommissionReason, example }: Props) {
  const reduce = useReducedMotion()
  const agentShare = price > 0n ? Number((commission * 10_000n) / price) / 100 : 0
  const sellerNet = price - commission
  const paid = commission > 0n

  return (
    <div className="card overflow-hidden p-5 sm:p-7">
      <div className="mb-5 flex items-center justify-between gap-3">
        <div className="flex items-center gap-2 text-sm font-semibold">
          <span className="flex size-8 items-center justify-center rounded-full" style={{ background: 'var(--surface-strong)' }}>
            <User className="size-4" />
          </span>
          Buyer pays <span className="tabular-nums">{fmtNumber(price)} USDC</span>
        </div>
        {example && <span className="chip">Example</span>}
      </div>

      <div className="relative mx-auto my-2 h-10 w-px" style={{ background: 'var(--border-strong)' }}>
        <ArrowDown className="absolute -bottom-1 left-1/2 size-4 -translate-x-1/2" style={{ color: 'var(--subtle)' }} />
        {!reduce && (
          <motion.span
            className="absolute left-1/2 size-2 -translate-x-1/2 rounded-full"
            style={{ background: 'var(--accent)' }}
            initial={{ top: 0, opacity: 1 }}
            animate={{ top: '100%', opacity: [1, 1, 0] }}
            transition={{ duration: 1.1, repeat: Infinity, ease: 'easeIn' }}
          />
        )}
      </div>

      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <motion.div
          className="inner p-4"
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.15, duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
        >
          <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--accent)' }}>
            <Store className="size-4" /> Seller
          </div>
          <div className="display text-3xl font-bold tabular-nums" style={{ color: 'var(--accent)' }}>
            +{fmtNumber(price)} <span className="text-base font-medium" style={{ color: 'var(--subtle)' }}>USDC</span>
          </div>
          <p className="mt-1 text-xs" style={{ color: 'var(--subtle)' }}>
            {paid ? `Keeps ${fmtNumber(sellerNet)} USDC after paying the commission from its own budget` : 'Receives the full price'}
          </p>
        </motion.div>

        <motion.div
          className="inner p-4"
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.35, duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
        >
          <div className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--agent)' }}>
            <Bot className="size-4" /> Agent
          </div>
          {paid ? (
            <>
              <div className="display text-3xl font-bold tabular-nums" style={{ color: 'var(--agent)' }}>
                +{fmtNumber(commission)} <span className="text-base font-medium" style={{ color: 'var(--subtle)' }}>USDC</span>
              </div>
              <p className="mt-1 text-xs" style={{ color: 'var(--subtle)' }}>Commission for the sale it referred</p>
            </>
          ) : (
            <>
              <div className="display text-2xl font-bold" style={{ color: 'var(--subtle)' }}>No commission</div>
              <p className="mt-1 text-xs" style={{ color: 'var(--subtle)' }}>{noCommissionReason ?? 'This sale paid no commission.'}</p>
            </>
          )}
        </motion.div>
      </div>

      <div className="mt-5" role="img" aria-label={`Seller ${100 - agentShare}% of the price, agent commission ${agentShare}%`}>
        <div className="flex h-3 overflow-hidden rounded-full" style={{ background: 'var(--surface-strong)' }}>
          <motion.div
            className="h-full origin-left"
            style={{ background: 'var(--accent)', width: `${100 - agentShare}%` }}
            initial={{ scaleX: 0 }}
            animate={{ scaleX: 1 }}
            transition={{ delay: 0.2, duration: 0.8, ease: [0.22, 1, 0.36, 1] }}
          />
          {paid && (
            <motion.div
              className="h-full origin-left"
              style={{ background: 'var(--agent)', width: `${agentShare}%` }}
              initial={{ scaleX: 0 }}
              animate={{ scaleX: 1 }}
              transition={{ delay: 0.7, duration: 0.5, ease: [0.22, 1, 0.36, 1] }}
            />
          )}
        </div>
        <div className="mt-2 flex justify-between text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
          <span>Seller {(100 - agentShare).toFixed(agentShare % 1 === 0 ? 0 : 1)}% of the price</span>
          <span>Agent {agentShare.toFixed(agentShare % 1 === 0 ? 0 : 1)}%</span>
        </div>
      </div>
    </div>
  )
}
