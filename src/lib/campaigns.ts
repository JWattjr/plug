import { fmtBps, commissionFor, fmtNumber } from '@/lib/money'
import { PLUG } from '@/plug.config'

/** A campaign as stored by the contract, plus its id. */
export interface Campaign {
  id: bigint
  advertiser: `0x${string}`
  title: string
  offerUrl: string
  price: bigint
  commissionBps: number
  budgetRemaining: bigint
  endTime: bigint
  active: boolean
  sales: bigint
  commissionPaid: bigint
}

/** Open for purchases right now: not closed and not past its end time. */
export function isLive(campaign: Campaign, now: number): boolean {
  return campaign.active && Number(campaign.endTime) > now
}

export function commissionPerSale(campaign: Campaign): bigint {
  return commissionFor(campaign.price, campaign.commissionBps)
}

/** The budget can still pay at least one commission. */
export function canPayCommission(campaign: Campaign): boolean {
  return campaign.budgetRemaining >= commissionPerSale(campaign)
}

/** On-chain text is untrusted: only ever link to http(s) URLs. */
export function safeHref(url: string): string | undefined {
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'https:' || parsed.protocol === 'http:' ? parsed.toString() : undefined
  } catch {
    return undefined
  }
}

/** Safe to embed inside a <script type="application/json"> tag. */
export function escapeForScriptTag(json: string): string {
  return json.replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029')
}

/** Machine-readable offer, what an agent needs to recommend and settle. */
export function toOfferJson(campaign: Campaign) {
  return {
    id: campaign.id.toString(),
    sponsored: true,
    title: campaign.title,
    offerUrl: campaign.offerUrl,
    seller: campaign.advertiser,
    price: { usdc: fmtNumber(campaign.price), raw: campaign.price.toString(), decimals: PLUG.usdcDecimals },
    commission: {
      percent: fmtBps(campaign.commissionBps),
      bps: campaign.commissionBps,
      perSaleRaw: commissionPerSale(campaign).toString(),
      payable: canPayCommission(campaign),
    },
    budgetRemainingRaw: campaign.budgetRemaining.toString(),
    endsAt: Number(campaign.endTime),
    settle: { contract: PLUG.address, chainId: PLUG.chainId, call: `buy(${campaign.id.toString()}, <referrer>)` },
  }
}
