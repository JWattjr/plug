import { PLUG } from '@/plug.config'
import { formatUnitsExact, parseUnitsExact } from '@/onchain-money'

const BPS_DENOMINATOR = 10_000n

/** Group a whole-number string with thousands separators. */
function group(whole: string): string {
  return whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
}

/** "1.00" style number: at least two fraction digits, up to the token's own precision. */
export function fmtNumber(raw: bigint): string {
  const exact = formatUnitsExact(raw, PLUG.usdcDecimals)
  const negative = exact.startsWith('-')
  const body = negative ? exact.slice(1) : exact
  const [whole, fraction = ''] = body.split('.')
  return `${negative ? '-' : ''}${group(whole)}.${fraction.padEnd(2, '0')}`
}

/** "1.00 USDC" */
export function fmtUsdc(raw: bigint): string {
  return `${fmtNumber(raw)} USDC`
}

/** Parse a user-typed USDC amount. Returns undefined when empty or invalid. */
export function parseUsdcInput(value: string): bigint | undefined {
  const trimmed = value.trim()
  if (!trimmed || trimmed === '.') return undefined
  try {
    return parseUnitsExact(trimmed, PLUG.usdcDecimals)
  } catch {
    return undefined
  }
}

/** Same floor division the contract performs: price * bps / 10000. */
export function commissionFor(price: bigint, commissionBps: number | bigint): bigint {
  return (price * BigInt(commissionBps)) / BPS_DENOMINATOR
}

/** 1000 bps -> "10%", 250 bps -> "2.5%" */
export function fmtBps(bps: number): string {
  const pct = bps / 100
  return `${Number.isInteger(pct) ? pct.toFixed(0) : pct.toString()}%`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

export function sameAddress(a?: string, b?: string): boolean {
  return Boolean(a && b && a.toLowerCase() === b.toLowerCase())
}
