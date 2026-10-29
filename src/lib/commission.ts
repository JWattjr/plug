import { canPayCommission, isProtected, type Campaign } from '@/lib/campaigns'
import { PLUG } from '@/plug.config'
import { commissionFor, sameAddress } from '@/lib/money'

export interface CommissionOutlook {
  /** Commission the contract is expected to pay, in raw USDC. */
  commission: bigint
  /** Why no commission is paid. Undefined when one is. */
  reason?: string
}

const ZERO = '0x0000000000000000000000000000000000000000'

/**
 * Mirrors the contract's eligibility rules so the UI can say what a purchase will
 * pay before it happens, and why a commission is zero afterwards.
 */
export function explainCommission(campaign: Campaign, referrer: string | undefined, buyer: string | undefined): CommissionOutlook {
  if (!referrer || sameAddress(referrer, ZERO)) return { commission: 0n, reason: 'No agent referred this sale.' }
  if (sameAddress(referrer, buyer)) return { commission: 0n, reason: 'Self-referral: a buyer cannot earn commission on their own purchase.' }
  if (sameAddress(referrer, campaign.advertiser)) return { commission: 0n, reason: 'Self-referral: the seller cannot earn commission on its own sale.' }
  if (sameAddress(referrer, PLUG.address)) return { commission: 0n, reason: 'The contract itself cannot be a referrer.' }
  if (isProtected(campaign) && sameAddress(referrer, campaign.arbiter)) return { commission: 0n, reason: 'The arbiter cannot earn commission on orders it may have to decide.' }
  if (campaign.commissionBps === 0) return { commission: 0n, reason: 'This campaign pays no commission.' }
  const commission = commissionFor(campaign.price, campaign.commissionBps)
  if (commission === 0n) return { commission: 0n, reason: 'The commission rounds down to zero at this price.' }
  if (!canPayCommission(campaign)) return { commission: 0n, reason: 'The campaign budget is empty, so it can no longer pay a commission.' }
  return { commission }
}

/** Reason to show after the fact, when the chain paid less than expected. */
export const UNDELIVERABLE_REASON = 'The agent address could not receive USDC, so the commission was skipped and the sale still went through.'
