export const nowSeconds = (): number => Math.floor(Date.now() / 1000)

/** "3d 4h", "2h 10m", "45s", or "Ended". */
export function fmtTimeLeft(endTime: bigint | number, now: number = nowSeconds()): string {
  const remaining = Number(endTime) - now
  if (remaining <= 0) return 'Ended'
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
