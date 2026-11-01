import { ErrorNote, InfoNote, Spinner } from '@/components/ui'
import type { useApproval } from '@/hooks/useApproval'

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

/** Explains why no approval is on offer. Shown under the action button. */
export function ApprovalNotice({ approval, onStartOver }: { approval: Approval; onStartOver: () => void }) {
  return (
    <>
      {approval.gate.kind === 'error' && !approval.unconfirmed && (
        <ErrorNote>
          We could not read your USDC allowance from the network, so Plug is not asking you to approve. Retry the check. Nothing has been spent.
        </ErrorNote>
      )}
      {approval.unconfirmed && approval.gate.kind !== 'ready' && approval.gate.kind !== 'none' && (
        <InfoNote>
          Your approval was sent. Plug keeps checking the chain and moves on once it lands, so do not approve again.{' '}
          <button type="button" className="underline" onClick={onStartOver}>The transaction never appeared? Start over</button>
        </InfoNote>
      )}
    </>
  )
}
