import { useSyncExternalStore } from 'react'
import type { DescribedError } from '@/lib/rpc'

/**
 * A short, redacted log of how network reads were answered. It is what lets a screen say
 * "the public Arc RPC failed, your wallet answered" and show the real error, even when the
 * read finally succeeded. Hosts only; never URLs with paths or keys.
 */
export interface ReadEvent {
  id: number
  at: number
  method: string
  route: 'http' | 'wallet'
  ok: boolean
  ms: number
  hosts: string[]
  error?: DescribedError
}

const MAX_EVENTS = 60
let events: readonly ReadEvent[] = []
let nextId = 1
const listeners = new Set<() => void>()

export function recordRead(event: Omit<ReadEvent, 'id' | 'at'>): void {
  events = [...events, { ...event, id: nextId++, at: Date.now() }].slice(-MAX_EVENTS)
  for (const listener of listeners) listener()
}

export function clearReadLog(): void {
  events = []
  for (const listener of listeners) listener()
}

export function getReadLog(): readonly ReadEvent[] {
  return events
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function useReadLog(): readonly ReadEvent[] {
  return useSyncExternalStore(subscribe, getReadLog, getReadLog)
}

/** What the log says right now: did the public route fail, and did the wallet answer instead? */
export function summarizeReadLog(log: readonly ReadEvent[], sinceMs: number, now = Date.now()) {
  const recent = log.filter((e) => now - e.at <= sinceMs)
  const httpFailures = recent.filter((e) => e.route === 'http' && !e.ok)
  const walletAnswers = recent.filter((e) => e.route === 'wallet' && e.ok)
  const walletFailures = recent.filter((e) => e.route === 'wallet' && !e.ok)
  return { recent, httpFailures, walletAnswers, walletFailures }
}
