import { AllowanceReadError, SOURCE_LABEL, type AllowanceReading, type ReadAttempt } from '@/lib/allowance'
import { describeError, redact } from '@/lib/rpc'

export interface AllowanceReportInput {
  owner?: string
  /** Chain id the wallet reports, if connected. */
  walletChainId?: number
  targetChainId: number
  targetChainName: string
  spender?: string
  token?: string
  /** Amount the screen needs allowed, formatted for display. */
  needed?: string
  rpcHosts: readonly string[]
  error?: unknown
  reading?: AllowanceReading
  /** Formats a raw USDC amount for display. */
  format: (raw: bigint) => string
}

function attemptLine(a: ReadAttempt, format: (raw: bigint) => string): string {
  const where = a.hosts.join(', ')
  if (a.ok) return `${SOURCE_LABEL[a.source]} (${where}): answered ${a.value === undefined ? '' : format(a.value)} in ${a.ms} ms`
  const e = a.error
  const bits = [e?.shortMessage ?? 'failed']
  if (e?.status !== undefined) bits.push(`HTTP ${e.status}`)
  if (e?.code !== undefined) bits.push(`code ${e.code}`)
  if (e?.host && e.host !== where) bits.push(`from ${e.host}`)
  if (e?.details && e.details !== e.shortMessage) bits.push(e.details)
  return `${SOURCE_LABEL[a.source]} (${where}): ${bits.join(' | ')}`
}

/** Plain-text facts about one allowance read. Safe to show and to copy: hosts only, no keys. */
export function buildAllowanceReport(input: AllowanceReportInput): string[] {
  const lines: string[] = []
  lines.push(`Connected account: ${input.owner ?? 'none'}`)
  lines.push(`Wallet network: ${input.walletChainId ?? 'unknown'}`)
  lines.push(`Target network: ${input.targetChainName} (chain ${input.targetChainId})`)
  lines.push(`Spender (Plug): ${input.spender ?? 'not configured'}`)
  lines.push(`USDC token: ${input.token ?? 'not configured'}`)
  if (input.needed) lines.push(`Needed: ${input.needed}`)
  lines.push(`RPC hosts: ${input.rpcHosts.join(', ')}`)

  const attempts = input.error instanceof AllowanceReadError ? input.error.attempts : input.reading?.attempts
  if (attempts?.length) {
    attempts.forEach((a, i) => lines.push(`Attempt ${i + 1}: ${attemptLine(a, input.format)}`))
  } else if (input.error) {
    const e = describeError(input.error)
    lines.push(`Error: ${e.shortMessage}${e.details ? ` | ${e.details}` : ''}`)
  }
  if (input.reading) lines.push(`Result: ${input.format(input.reading.value)} via ${SOURCE_LABEL[input.reading.source]}`)
  const at = input.error instanceof AllowanceReadError ? input.error.checkedAt : input.reading?.checkedAt
  if (at) lines.push(`Checked at: ${new Date(at).toISOString()}`)
  return lines.map((line) => redact(line))
}
