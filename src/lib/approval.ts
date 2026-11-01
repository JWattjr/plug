import { erc20Abi, parseEventLogs, type TransactionReceipt } from 'viem'

/**
 * The USDC allowance gate for the Advertise flow.
 *
 * The rule that matters: an allowance we have not actually read is UNKNOWN, never
 * zero. Only a successful read (or a verified approval receipt) may decide that an
 * approval is needed, because an approval costs the user a real fee.
 */

/** The slice of a react-query result the gate needs. */
export interface AllowanceRead {
  /** Last successfully read allowance in raw USDC units, if any. */
  data: bigint | undefined
  /** No data yet. */
  isPending: boolean
  /** The latest attempt failed. `data` may still hold an older successful read. */
  isError: boolean
  /** The query cannot run (no owner, no client, or Plug not configured). */
  isIdle: boolean
}

export type ApprovalGate =
  /** Budget is zero, so nothing needs to be locked. */
  | { kind: 'none' }
  /** The allowance has not been read yet. Do not offer an approval. */
  | { kind: 'loading' }
  /** The allowance could not be read. Offer a retry, never an approval. */
  | { kind: 'error' }
  /** A fresh read says the allowance is below the budget. Approval is safe to offer. */
  | { kind: 'required'; have: bigint }
  /** Allowance covers the budget. Go straight to Create campaign. */
  | { kind: 'ready'; have: bigint; fromReceipt: boolean }

export interface ApprovalGateInput {
  budget: bigint
  read: AllowanceRead
  /** Amount proven by a successful approval receipt for this chain, owner and spender. */
  receiptAmount: bigint
}

export function resolveApprovalGate({ budget, read, receiptAmount }: ApprovalGateInput): ApprovalGate {
  if (budget <= 0n) return { kind: 'none' }

  const readHave = read.data
  const have = readHave !== undefined && readHave > receiptAmount ? readHave : receiptAmount

  // A mined approval that covers the budget is proof, even if the read is failing.
  if (have >= budget) return { kind: 'ready', have, fromReceipt: readHave === undefined || receiptAmount > readHave }

  if (read.isIdle) return { kind: 'error' }
  // Any failed attempt means the number we hold may be out of date, so do not trust "too low".
  if (read.isError) return { kind: 'error' }
  if (readHave === undefined) return read.isPending ? { kind: 'loading' } : { kind: 'error' }
  return { kind: 'required', have }
}

/** Identifies one (chain, token, owner, spender) allowance. Used to scope receipt proof. */
export function approvalKey(chainId: number, token: string, owner: string, spender: string): string {
  return [chainId, token, owner, spender].map((p) => String(p).toLowerCase()).join(':')
}

/**
 * The allowance a receipt proves, read from its ERC-20 Approval event for this exact
 * token, owner and spender. Returns 0n when the receipt did not set one.
 */
export function approvedAmountFromReceipt(
  receipt: Pick<TransactionReceipt, 'logs'>,
  match: { token: string; owner: string; spender: string },
): bigint {
  const events = parseEventLogs({ abi: erc20Abi, logs: receipt.logs, eventName: 'Approval', strict: false })
  let amount = 0n
  for (const event of events) {
    if (event.address.toLowerCase() !== match.token.toLowerCase()) continue
    const { owner, spender, value } = event.args
    if (!owner || !spender || value === undefined) continue
    if (owner.toLowerCase() !== match.owner.toLowerCase()) continue
    if (spender.toLowerCase() !== match.spender.toLowerCase()) continue
    amount = value // the last matching event wins, like the contract state would
  }
  return amount
}
