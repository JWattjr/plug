import { useState } from 'react'
import { ErrorNote, Spinner } from '@/components/ui'
import { redact, describeError, rpcHost } from '@/lib/rpc'
import { summarizeReadLog, useReadLog, type ReadEvent } from '@/lib/readLog'
import { PLUG } from '@/plug.config'

const RECENT_MS = 10 * 60 * 1000

function eventLine(e: ReadEvent): string {
  const when = new Date(e.at).toISOString().slice(11, 19)
  const where = e.route === 'wallet' ? 'wallet' : e.hosts.join(', ')
  const head = `${when} ${e.method} via ${where}: ${e.ok ? `answered in ${e.ms} ms` : 'failed'}`
  if (e.ok || !e.error) return head
  const bits = [e.error.shortMessage]
  if (e.error.status !== undefined) bits.push(`HTTP ${e.error.status}`)
  if (e.error.code !== undefined) bits.push(`code ${e.error.code}`)
  if (e.error.details && e.error.details !== e.error.shortMessage) bits.push(e.error.details)
  return redact(`${head} | ${bits.join(' | ')}`)
}

/** Redacted lines for the recent read attempts. Hosts only; safe to copy. */
export function readLogLines(log: readonly ReadEvent[], limit = 12): string[] {
  return log.slice(-limit).map(eventLine)
}

function Details({ lines, open }: { lines: string[]; open?: boolean }) {
  const [copied, setCopied] = useState(false)
  const text = lines.join('\n')
  return (
    <details className="mt-2 text-xs" open={open} data-testid="read-diagnostics">
      <summary className="cursor-pointer font-semibold">Technical details</summary>
      <pre className="mono mt-2 whitespace-pre-wrap break-all rounded-xl p-3 leading-relaxed" style={{ background: 'var(--surface-strong)', color: 'var(--muted)' }}>{text}</pre>
      <button
        type="button"
        className="mt-2 underline"
        onClick={() => {
          void navigator.clipboard?.writeText(text).then(() => setCopied(true), () => setCopied(false))
        }}
      >
        {copied ? 'Copied' : 'Copy details'}
      </button>
    </details>
  )
}

/**
 * A read failed and there is nothing real to show. Says so plainly (never "none yet"), offers a retry,
 * and lists what was tried.
 */
export function ReadError({ what, error, onRetry, retrying }: { what: string; error: unknown; onRetry?: () => void; retrying?: boolean }) {
  const log = useReadLog()
  const own = describeError(error)
  const lines = [
    `Target network: ${PLUG.chainName} (chain ${PLUG.chainId})`,
    `Contract (Plug): ${PLUG.address ?? 'not configured'}`,
    `RPC hosts: ${PLUG.rpcUrls.map(rpcHost).join(', ')}`,
    `Error: ${own.shortMessage}${own.details ? ` | ${own.details}` : ''}`,
    ...readLogLines(log),
  ].map((l) => redact(l))
  return (
    <ErrorNote>
      <p>
        Could not read {what} from {PLUG.chainName}. This is a loading problem, not an empty result: nothing here has been lost or changed.
      </p>
      <div className="mt-2 flex items-center gap-3">
        {onRetry && (
          <button type="button" className="btn btn-ghost !min-h-9" disabled={retrying} onClick={onRetry}>
            {retrying ? <Spinner /> : null} Retry
          </button>
        )}
      </div>
      <Details lines={lines} open />
    </ErrorNote>
  )
}

/**
 * Shown on every page when the public Arc route failed recently, including when the connected wallet
 * answered instead, so the failed attempt can still be inspected.
 */
export function ReadRouteNotice() {
  const log = useReadLog()
  const { httpFailures, walletAnswers, walletFailures } = summarizeReadLog(log, RECENT_MS)
  if (httpFailures.length === 0) return null
  const rescued = walletAnswers.length > 0
  return (
    <div className="mx-auto max-w-6xl px-4 pt-3" data-testid="read-route-notice">
      <div className="inner px-4 py-3 text-xs" style={{ color: 'var(--muted)' }}>
        <p>
          {rescued
            ? 'The public Arc RPC did not answer some reads, so your wallet answered them instead. Everything shown was verified on the Arc network your wallet reports.'
            : walletFailures.length > 0
              ? 'The public Arc RPC did not answer some reads and your wallet could not answer them either. Some data may be missing until a read succeeds.'
              : 'The public Arc RPC did not answer some reads. Connect your wallet to let it help, or retry.'}
        </p>
        <Details lines={readLogLines(log)} />
      </div>
    </div>
  )
}
