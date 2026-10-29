/**
 * Chain-aware clock. The contract compares against block.timestamp, so the app
 * keeps an offset between the browser clock and the latest block and uses it
 * everywhere it needs "now".
 */
let clockOffsetSeconds = 0

export function setClockOffset(offset: number): void {
  clockOffsetSeconds = offset
}

export const nowSeconds = (): number => Math.floor(Date.now() / 1000) + clockOffsetSeconds

/** "3d 4h", "2h 10m", "45s", or "Ended". */
export function fmtTimeLeft(endTime: bigint | number, now: number = nowSeconds(), done = 'Ended'): string {
  const remaining = Number(endTime) - now
  if (remaining <= 0) return done
  const days = Math.floor(remaining / 86_400)
  const hours = Math.floor((remaining % 86_400) / 3_600)
  const minutes = Math.floor((remaining % 3_600) / 60)
  const seconds = remaining % 60
  if (days > 0) return `${days}d ${hours}h`
  if (hours > 0) return `${hours}h ${minutes}m`
  if (minutes > 0) return `${minutes}m ${seconds}s`
  return `${seconds}s`
}

export function fmtDate(seconds: number | bigint): string {
  return new Date(Number(seconds) * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

/** 604800 -> "7-day", 43200 -> "12-hour" */
export function fmtWindow(seconds: bigint | number): string {
  const s = Number(seconds)
  if (s % 86_400 === 0) return `${s / 86_400}-day`
  if (s % 3_600 === 0) return `${s / 3_600}-hour`
  return `${Math.round(s / 60)}-minute`
}

/** 604800 -> "7 days", 86400 -> "1 day", 43200 -> "12 hours" */
export function fmtWindowLong(seconds: bigint | number): string {
  const s = Number(seconds)
  const plural = (n: number, unit: string) => `${n} ${unit}${n === 1 ? '' : 's'}`
  if (s % 86_400 === 0) return plural(s / 86_400, 'day')
  if (s % 3_600 === 0) return plural(s / 3_600, 'hour')
  return plural(Math.round(s / 60), 'minute')
}
