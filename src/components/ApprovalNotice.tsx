import { useState } from 'react'
import { useAccount } from 'wagmi'
import { ErrorNote, InfoNote, Spinner } from '@/components/ui'
import type { useApproval } from '@/hooks/useApproval'
import { buildAllowanceReport } from '@/lib/allowanceReport'
import { fmtUsdc, shortAddress } from '@/lib/money'
import { rpcHost } from '@/lib/rpc'
import { PLUG } from '@/plug.config'

type Approval = ReturnType<typeof useApproval>

/** True when no approval may be offered right now: the allowance is unknown, or an approval is still in flight. */
export function holdsApproval(approval: Approval): boolean {
  const kind = approval.gate.kind
  return kind === 'loading' || kind === 'error' || (kind === 'required' && approval.unconfirmed)
}

/** Replaces the paid "Allow" button while the allowance is loading, unreadable or unconfirmed. */
export function ApprovalHoldButton({ approval, disabled, className = 'btn w-full', compact }: { approval: Approval; disabled?: boolean; className?: string; compact?: boolean }) {
  if (approval.gate.kind === 'loading') {
    return (
      <button className={`${className} btn-primary`} disabled>
        <Spinner /> {compact ? 'Checking' : 'Checking your USDC allowance'}
      </button>
    )
  }
  return (
    <button className={`${className} btn-ghost`} disabled={approval.retrying || disabled} onClick={approval.retry}>
      {approval.retrying ? <Spinner /> : null} {approval.unconfirmed ? 'Check allowance again' : compact ? 'Retry' : 'Retry allowance check'}
    </button>
  )
}

/** The facts behind one allowance read, as plain text lines. Hosts only; never keys or full URLs. */
export function useAllowanceReport(approval: Approval, needed?: bigint): string[] {
  const { chainId } = useAccount()
  return buildAllowanceReport({
    owner: approval.owner,
    walletChainId: chainId,
    targetChainId: PLUG.chainId,
    targetChainName: PLUG.chainName,
    spender: PLUG.address,
    token: PLUG.usdcAddress,
    needed: needed !== undefined ? fmtUsdc(needed) : undefined,
    rpcHosts: PLUG.rpcUrls.map(rpcHost),
    error: approval.error,
    reading: approval.error ? undefined : approval.reading,
    format: fmtUsdc,
  })
}

function Diagnostics({ lines, defaultOpen }: { lines: string[]; defaultOpen?: boolean }) {
  const [copied, setCopied] = useState(false)
  const text = lines.join('\n')
  return (
    <details className="mt-2 text-xs" open={defaultOpen} data-testid="allowance-diagnostics">
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

/** Which account Plug is checking, and what that account has allowed. Makes an owner mismatch obvious. */
export function AllowanceSummary({ approval }: { approval: Approval }) {
  const owner = approval.owner
  if (!owner) return null
  const reading = approval.reading
  return (
    <div className="inner space-y-1 px-4 py-3 text-xs" style={{ color: 'var(--muted)' }} data-testid="allowance-summary">
      <p>
        Checking account <span className="mono font-semibold" title={owner} style={{ color: 'var(--ink)' }}>{shortAddress(owner)}</span> (the account selected in your wallet).
      </p>
      {reading && (
        <p className="tabular-nums">
          Plug is allowed to use <span className="font-semibold" style={{ color: 'var(--ink)' }}>{fmtUsdc(reading.value)}</span> from this account.
        </p>
      )}
      {reading && reading.value === 0n && (
        <p>
          This account has not allowed Plug any USDC. If you approved from a different account, switch to that account in your wallet and this page will update.
        </p>
      )}
    </div>
  )
}

/** Explains why no approval is on offer. Shown under the action button. */
export function ApprovalNotice({ approval, onStartOver, needed }: { approval: Approval; onStartOver: () => void; needed?: bigint }) {
  const report = useAllowanceReport(approval, needed)
  const failed = approval.gate.kind === 'error' && !approval.unconfirmed
  return (
    <>
      {failed && (
        <ErrorNote>
          <p>
            We could not read your USDC allowance from the network, so Plug is not asking you to approve. Nothing has been spent. Retry the check, or open the technical details below to see exactly what failed.
          </p>
          <Diagnostics lines={report} defaultOpen />
        </ErrorNote>
      )}
      {approval.unconfirmed && approval.gate.kind !== 'ready' && approval.gate.kind !== 'none' && (
        <InfoNote>
          Your approval was sent. Plug keeps checking the chain and moves on once it lands, so do not approve again.{' '}
          <button type="button" className="underline" onClick={onStartOver}>The transaction never appeared? Start over</button>
        </InfoNote>
      )}
      {!failed && approval.reading && approval.reading.attempts.some((a) => !a.ok) && (
        <div className="text-xs" style={{ color: 'var(--subtle)' }}>
          <p>
            Read through {approval.reading.source === 'wallet' ? 'your wallet' : 'a direct Arc RPC call'} because the usual route did not answer.
          </p>
          <Diagnostics lines={report} />
        </div>
      )}
    </>
  )
}
