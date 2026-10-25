import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from 'viem'
import { PLUG } from '@/plug.config'

/** Returned for a wallet rejection. The UI resets quietly instead of showing an error. */
export const CANCELLED = 'cancelled'

const CONTRACT_ERRORS: Record<string, string> = {
  CampaignExpired: 'This campaign has ended, so it no longer accepts purchases.',
  CampaignInactive: 'This campaign was closed by the seller.',
  CampaignNotFound: 'This campaign does not exist.',
  Unauthorized: 'Only the seller can do that before the campaign ends.',
  InvalidPrice: 'Price must be greater than zero.',
  InvalidCommissionBps: 'Commission cannot be higher than 50%.',
  InvalidEndTime: 'The end time must be in the future.',
  TitleTooLong: 'The title is too long (128 bytes max).',
  OfferUrlTooLong: 'The offer URL is too long (512 bytes max).',
  ReentrancyGuardReentrantCall: 'The contract rejected a re-entrant call.',
}

/** Turn any wallet, RPC or revert failure into one readable sentence. Null means "user cancelled". */
export function parseOnchainError(error: unknown): string | null {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return null

    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (reverted instanceof ContractFunctionRevertedError && reverted.data?.errorName) {
      const known = CONTRACT_ERRORS[reverted.data.errorName]
      if (known) return known
    }
  }

  const code = (error as { code?: number } | null)?.code
  const message = (error instanceof Error ? error.message : typeof error === 'string' ? error : '').toLowerCase()

  if (code === 4001 || message.includes('user rejected') || message.includes('user denied')) return null
  if (message.includes('exceeds balance') || message.includes('insufficient funds') || message.includes('insufficient balance')) {
    return 'Insufficient USDC. Add test USDC with the Arc Studio faucet and try again.'
  }
  if (message.includes('allowance')) {
    return 'USDC allowance is too low. Allow USDC first, then try again.'
  }
  for (const [name, text] of Object.entries(CONTRACT_ERRORS)) {
    if (message.includes(name.toLowerCase())) return text
  }
  if (message.includes('chain') && (message.includes('mismatch') || message.includes('switch'))) {
    return `Wrong network. Switch your wallet to ${PLUG.chainName}.`
  }
  if (message.includes('network') || message.includes('timeout') || message.includes('fetch')) {
    return 'Network issue. Check your connection and try again.'
  }
  if (message.includes('reverted')) return 'The transaction was rejected by the contract. Refresh and try again.'
  return 'Something went wrong. Please try again.'
}
