import type { Hash } from 'viem'

/**
 * A sent-but-unconfirmed transaction hash, kept per chain, contract, account and action so a
 * page reload can check its status instead of offering the same action again.
 * Only the hash and a timestamp are stored.
 */
export interface PendingTx {
  hash: Hash
  at: number
}

const HASH_RE = /^0x[0-9a-fA-F]{64}$/

export function pendingKey(parts: { chainId: number; contract?: string; account?: string; scope: string }): string | undefined {
  if (!parts.account || !parts.contract) return undefined
  return `plug:pending:${parts.chainId}:${parts.contract.toLowerCase()}:${parts.account.toLowerCase()}:${parts.scope}`
}

function storage(): Storage | undefined {
  try {
    return typeof localStorage === 'undefined' ? undefined : localStorage
  } catch {
    return undefined
  }
}

export function loadPending(key: string | undefined): PendingTx | undefined {
  if (!key) return undefined
  try {
    const raw = storage()?.getItem(key)
    if (!raw) return undefined
    const parsed = JSON.parse(raw) as Partial<PendingTx>
    return typeof parsed.hash === 'string' && HASH_RE.test(parsed.hash) ? { hash: parsed.hash, at: Number(parsed.at) || 0 } : undefined
  } catch {
    return undefined
  }
}

export function savePending(key: string | undefined, hash: Hash): void {
  if (!key) return
  try {
    storage()?.setItem(key, JSON.stringify({ hash, at: Date.now() } satisfies PendingTx))
  } catch {
    // Storage can be unavailable (private mode). The on-screen state still protects this session.
  }
}

export function clearPending(key: string | undefined): void {
  if (!key) return
  try {
    storage()?.removeItem(key)
  } catch {
    // ignore
  }
}
