import { Check, X } from 'lucide-react'
import { motion } from 'framer-motion'
import type { TimelineStep } from '@/lib/orders'

/** Horizontal status timeline: Paid, Held, then Released or Refunded (or the dispute path). */
export function OrderTimeline({ steps }: { steps: TimelineStep[] }) {
  return (
    <ol className="flex items-start" aria-label="Order status">
      {steps.map((step, i) => {
        const last = i === steps.length - 1
        const color =
          step.state === 'done' ? 'var(--success)' : step.state === 'bad' ? 'var(--danger)' : step.state === 'current' ? 'var(--agent)' : 'var(--surface-strong)'
        const ink = step.state === 'todo' ? 'var(--subtle)' : 'var(--accent-ink)'
        return (
          <li key={step.label} className={`flex ${last ? '' : 'flex-1'} items-start`} data-state={step.state}>
            <div className="flex w-16 flex-col items-center gap-1.5 text-center">
              <motion.span
                className="flex size-7 items-center justify-center rounded-full text-xs font-bold"
                style={{ background: color, color: ink }}
                animate={step.state === 'current' ? { scale: [1, 1.12, 1] } : { scale: 1 }}
                transition={step.state === 'current' ? { duration: 1.6, repeat: Infinity } : undefined}
              >
                {step.state === 'done' ? <Check className="size-4" /> : step.state === 'bad' ? <X className="size-4" /> : i + 1}
              </motion.span>
              <span className="text-[0.7rem] font-semibold leading-tight" style={{ color: step.state === 'todo' ? 'var(--subtle)' : 'var(--ink)' }}>
                {step.label}
              </span>
              {step.detail && <span className="text-[0.62rem] leading-tight" style={{ color: 'var(--subtle)' }}>{step.detail}</span>}
            </div>
            {!last && <div className="mt-3.5 h-0.5 flex-1 rounded-full" style={{ background: step.state === 'done' ? 'var(--success)' : 'var(--surface-strong)' }} />}
          </li>
        )
      })}
    </ol>
  )
}
