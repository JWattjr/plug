import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ArrowRight, Bot, Lock, Split } from 'lucide-react'
import { Page, Skeleton } from '@/components/ui'
import { SplitVisual } from '@/components/SplitVisual'
import { useStats } from '@/hooks/useCampaigns'
import { fmtNumber, parseUsdcInput } from '@/lib/money'
import { PLUG_CONFIGURED } from '@/plug.config'

const STEPS = [
  { icon: Lock, title: 'Seller locks a budget', body: 'Set a price and a commission, then lock USDC to pay agents with. Unused budget comes back when you end the campaign.' },
  { icon: Bot, title: 'Agent recommends', body: 'An AI agent finds the offer, tells the buyer it is sponsored, and shares a link with its own payout address.' },
  { icon: Split, title: 'Sale splits on-chain', body: 'The buyer pays once. The seller gets the price and the agent gets its commission, in the same transaction.' },
]

function Stat({ label, value, loading }: { label: string; value: string; loading: boolean }) {
  return (
    <div className="inner p-4">
      <div className="text-xs font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>{label}</div>
      {loading ? <Skeleton className="mt-2 h-8 w-24" /> : <div className="display mt-1 text-3xl font-bold tabular-nums">{value}</div>}
    </div>
  )
}

export default function Home() {
  const stats = useStats()
  const loading = PLUG_CONFIGURED && stats.isLoading

  return (
    <Page>
      <section className="grid items-center gap-10 lg:grid-cols-[1.1fr_1fr]">
        <div>
          <span className="chip mb-5">Sponsored offers for AI agents, paid in USDC on Arc</span>
          <h1 className="display text-balance text-5xl font-bold leading-[1.02] sm:text-6xl">Ads for AI agents. Pay only when they sell.</h1>
          <p className="mt-5 max-w-xl text-pretty text-lg" style={{ color: 'var(--muted)' }}>
            No impressions, no clicks. A commission is paid only when a real purchase settles on-chain, so you never pay for traffic that does not buy.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link to="/advertise" className="btn btn-primary">Launch a campaign <ArrowRight className="size-4" /></Link>
            <Link to="/offers" className="btn btn-ghost">Browse live offers</Link>
          </div>
        </div>
        <motion.div initial={{ opacity: 0, scale: 0.96 }} animate={{ opacity: 1, scale: 1 }} transition={{ duration: 0.5 }}>
          <SplitVisual price={parseUsdcInput('10') ?? 0n} commission={parseUsdcInput('1') ?? 0n} example />
          <p className="mt-2 text-center text-xs" style={{ color: 'var(--subtle)' }}>Illustration: a 10 USDC sale with a 10% commission.</p>
        </motion.div>
      </section>

      <section className="mt-16 grid gap-4 md:grid-cols-3">
        {STEPS.map((step, i) => (
          <motion.div
            key={step.title}
            className="card card-lift p-6"
            initial={{ opacity: 0, y: 16 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true }}
            transition={{ delay: i * 0.08, duration: 0.45 }}
          >
            <div className="mb-4 flex items-center gap-3">
              <span className="flex size-10 items-center justify-center rounded-xl" style={{ background: 'var(--surface-strong)', color: 'var(--accent)' }}>
                <step.icon className="size-5" />
              </span>
              <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>STEP {i + 1}</span>
            </div>
            <h3 className="display text-xl font-semibold">{step.title}</h3>
            <p className="mt-2 text-pretty text-sm" style={{ color: 'var(--muted)' }}>{step.body}</p>
          </motion.div>
        ))}
      </section>

      <section className="mt-16">
        <div className="mb-4 flex items-end justify-between">
          <h2 className="display text-2xl font-semibold">Live on the contract</h2>
          <span className="text-xs" style={{ color: 'var(--subtle)' }}>Read from the chain, refreshed every few seconds</span>
        </div>
        <div className="grid gap-3 sm:grid-cols-3">
          <Stat label="Campaigns" value={stats.campaigns.toString()} loading={loading} />
          <Stat label="Sales" value={stats.sales.toString()} loading={loading} />
          <Stat label="Commission paid" value={`${fmtNumber(stats.commissionPaid)} USDC`} loading={loading} />
        </div>
        {stats.error && (
          <p className="mt-3 text-sm" style={{ color: 'var(--danger)' }}>Could not read the chain right now. Stats will retry.</p>
        )}
      </section>

      <section className="mt-16">
        <div className="card p-6 sm:p-8">
          <h2 className="display text-2xl font-semibold">Why farming it never pays</h2>
          <p className="mt-2 max-w-3xl text-pretty" style={{ color: 'var(--muted)' }}>
            The seller funds its own budget. If the seller buys from itself, it only moves its own money. Anyone else must pay the full price to earn back at most 50% of it. Every offer is sponsored, and agents must say so.
          </p>
        </div>
      </section>
    </Page>
  )
}
