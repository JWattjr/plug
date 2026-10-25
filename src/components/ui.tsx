import type { ReactNode } from 'react'
import { motion } from 'framer-motion'
import { Check, CircleAlert, ExternalLink, Loader2, Megaphone } from 'lucide-react'
import type { TxState } from '@/hooks/useTx'
import { buildTxExplorerUrl } from '@/onchain-facts'
import { PLUG } from '@/plug.config'

export function Page({ children, narrow }: { children: ReactNode; narrow?: boolean }) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.35, ease: [0.22, 1, 0.36, 1] }}
      className={narrow ? 'mx-auto max-w-xl' : ''}
    >
      {children}
    </motion.div>
  )
}

export function PageTitle({ title, subtitle }: { title: string; subtitle?: ReactNode }) {
  return (
    <div className="mb-8">
      <h1 className="display text-balance text-3xl font-bold sm:text-4xl">{title}</h1>
      {subtitle && <p className="mt-2 max-w-2xl text-pretty" style={{ color: 'var(--muted)' }}>{subtitle}</p>}
    </div>
  )
}

export function SponsoredBadge() {
  return (
    <span className="badge-sponsored">
      <Megaphone className="size-3" /> Sponsored
    </span>
  )
}

export function Skeleton({ className = '' }: { className?: string }) {
  return <div className={`skeleton ${className}`} aria-hidden />
}

export function TxLink({ hash, label = 'View on explorer' }: { hash: string; label?: string }) {
  return (
    <a
      className="inline-flex items-center gap-1 text-xs font-semibold underline-offset-2 hover:underline"
      style={{ color: 'var(--accent)' }}
      href={buildTxExplorerUrl(PLUG.chainId, hash)}
      target="_blank"
      rel="noreferrer"
    >
      {label} <ExternalLink className="size-3" />
    </a>
  )
}

export function ErrorNote({ children }: { children: ReactNode }) {
  return (
    <div
      role="alert"
      className="flex items-start gap-2 rounded-2xl border px-4 py-3 text-sm"
      style={{ background: 'rgba(239,122,134,0.10)', borderColor: 'rgba(239,122,134,0.35)', color: 'var(--danger)' }}
    >
      <CircleAlert className="mt-0.5 size-4 shrink-0" />
      <div>{children}</div>
    </div>
  )
}

export function InfoNote({ children }: { children: ReactNode }) {
  return (
    <div className="inner px-4 py-3 text-sm" style={{ color: 'var(--muted)' }}>
      {children}
    </div>
  )
}

/** Honest transaction status: only states the wallet or the chain reported. */
export function TxNotice({ state, waitingLabel = 'Confirm in your wallet' }: { state: TxState; waitingLabel?: string }) {
  if (state.status === 'wallet') {
    return (
      <p className="flex items-center gap-2 text-sm" style={{ color: 'var(--muted)' }}>
        <Loader2 className="size-4 animate-spin" /> {waitingLabel}
      </p>
    )
  }
  if (state.status === 'confirming') {
    return (
      <p className="flex flex-wrap items-center gap-2 text-sm" style={{ color: 'var(--muted)' }}>
        <Loader2 className="size-4 animate-spin" /> Waiting for confirmation <TxLink hash={state.hash} label="Track" />
      </p>
    )
  }
  if (state.status === 'error') return <ErrorNote>{state.message}</ErrorNote>
  return null
}

export type StepStatus = 'todo' | 'active' | 'done'

export function Step({ index, title, detail, status }: { index: number; title: string; detail?: ReactNode; status: StepStatus }) {
  return (
    <li className="flex items-start gap-3">
      <span
        className="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-bold tabular-nums"
        style={{
          background: status === 'done' ? 'var(--success)' : status === 'active' ? 'var(--accent)' : 'var(--surface-strong)',
          color: status === 'todo' ? 'var(--subtle)' : 'var(--accent-ink)',
        }}
      >
        {status === 'done' ? <Check className="size-4" /> : index}
      </span>
      <div>
        <div className="text-sm font-semibold" style={{ color: status === 'todo' ? 'var(--subtle)' : 'var(--ink)' }}>
          {title}
        </div>
        {detail && <div className="text-xs" style={{ color: 'var(--subtle)' }}>{detail}</div>}
      </div>
    </li>
  )
}

export function Spinner() {
  return <Loader2 className="size-4 animate-spin" />
}

export function EmptyState({ title, body, action }: { title: string; body: string; action?: ReactNode }) {
  return (
    <div className="card flex flex-col items-center gap-2 px-6 py-12 text-center">
      <h3 className="display text-xl font-semibold">{title}</h3>
      <p className="max-w-md text-pretty text-sm" style={{ color: 'var(--muted)' }}>{body}</p>
      {action && <div className="mt-3">{action}</div>}
    </div>
  )
}
