import type { Campaign } from '@/lib/campaigns'

/** The line every agent recommendation must open with. */
export const SPONSOR_DISCLOSURE = 'Sponsored: this seller pays me a commission if you buy.'

const STOPWORDS = new Set([
  'a', 'an', 'the', 'i', 'me', 'my', 'we', 'you', 'your', 'need', 'needs', 'want', 'wants', 'looking', 'look', 'for', 'to',
  'of', 'and', 'or', 'with', 'in', 'on', 'at', 'is', 'are', 'be', 'can', 'could', 'would', 'should', 'please', 'help',
  'find', 'get', 'buy', 'some', 'any', 'good', 'best', 'cheap', 'new', 'that', 'this', 'it', 'do', 'have', 'has', 'about',
  'show', 'recommend', 'suggest', 'something', 'anything', 'like', 'what', 'which', 'where', 'how', 'am', 'im', 'ive',
])

export function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .split(/\s+/)
    .filter((token) => token.length > 1 && !STOPWORDS.has(token))
    .map(stem)
}

/** Very small stemmer: enough to match "headphone" with "headphones". */
function stem(token: string): string {
  if (token.length > 4 && token.endsWith('ies')) return `${token.slice(0, -3)}y`
  if (token.length > 3 && token.endsWith('es') && /(ch|sh|x|s|z)es$/.test(token)) return token.slice(0, -2)
  if (token.length > 3 && token.endsWith('s') && !token.endsWith('ss')) return token.slice(0, -1)
  return token
}

export interface Match {
  campaign: Campaign
  score: number
}

function urlWords(url: string): string[] {
  try {
    const parsed = new URL(url)
    return tokenize(`${parsed.hostname.replace(/^www\./, '')} ${parsed.pathname}`.replace(/[./_-]/g, ' '))
  } catch {
    return tokenize(url.replace(/[./_-]/g, ' '))
  }
}

/**
 * Keyword match. No model, no hidden ranking: every query word that appears in a
 * title scores 3, in the URL scores 1, a shared 4-letter prefix scores 1.
 * Ties go to the lower price, never to the higher commission.
 */
export function rankOffers(query: string, offers: readonly Campaign[]): Match[] {
  const queryTokens = Array.from(new Set(tokenize(query)))
  if (queryTokens.length === 0) return []

  const matches: Match[] = []
  for (const campaign of offers) {
    const titleTokens = tokenize(campaign.title)
    const urlTokens = urlWords(campaign.offerUrl)
    let score = 0
    for (const word of queryTokens) {
      if (titleTokens.includes(word)) score += 3
      else if (word.length >= 4 && titleTokens.some((t) => t.length >= 4 && t.slice(0, 4) === word.slice(0, 4))) score += 1
      if (urlTokens.includes(word)) score += 1
    }
    if (score > 0) matches.push({ campaign, score })
  }

  return matches.sort((a, b) => b.score - a.score || (a.campaign.price < b.campaign.price ? -1 : a.campaign.price > b.campaign.price ? 1 : 0))
}
