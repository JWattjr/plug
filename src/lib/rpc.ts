import { BaseError, fallback, http, type Transport } from 'viem'

/** Per-endpoint request timeout. A dead endpoint fails over quickly instead of hanging the page. */
const ENDPOINT_TIMEOUT_MS = 6_000

/**
 * One transport over the given endpoints. With several, the first is tried first and a
 * failing endpoint (rate limit, outage, network error) hands the same request to the next.
 * Contract reverts and wallet rejections are never retried elsewhere.
 */
export function rpcTransport(urls: readonly string[]): Transport {
  const transports = urls.map((url) => http(url, { timeout: ENDPOINT_TIMEOUT_MS }))
  if (transports.length === 1) return transports[0]
  return fallback(transports, { rank: false, retryCount: 1, retryDelay: 300 })
}

/** The host of an RPC URL. Path, query and credentials (where API keys live) are dropped. */
export function rpcHost(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return 'invalid RPC URL'
  }
}

const URL_RE = /\bhttps?:\/\/[^\s"'<>)]+/gi
const BEARER_RE = /\bbearer\s+[^\s"',;]+/gi
const SECRET_PAIR_RE = /\b(api[-_]?key|key|token|_rpc_token|secret|auth(?:orization)?|password)(\s*[=:]\s*)([^\s&"',;]+)/gi
/** A bare account or contract address is public data, not a credential, even after the word "token". */
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/

/** Strip anything that could carry a credential before text is shown or copied. */
export function redact(text: string): string {
  return text
    .replace(URL_RE, (match) => rpcHost(match))
    .replace(BEARER_RE, 'Bearer [redacted]')
    .replace(SECRET_PAIR_RE, (match, key: string, sep: string, value: string) => (ADDRESS_RE.test(value) ? match : `${key}${sep}[redacted]`))
}

export interface DescribedError {
  name: string
  shortMessage: string
  /** Server or transport detail, e.g. "rate limit exceeded". Redacted and trimmed. */
  details?: string
  /** HTTP status when the failure was an HTTP response, e.g. 429. */
  status?: number
  /** JSON-RPC or provider error code, e.g. -32005 or 4001. */
  code?: number
  /** Host of the endpoint that failed, when the error names one. */
  host?: string
}

const MAX_DETAIL = 300

/** Turn any thrown value into plain, safe, displayable facts. Never includes URLs' paths or keys. */
export function describeError(error: unknown): DescribedError {
  if (error instanceof BaseError) {
    const fields = findFields(error)
    return {
      name: error.name,
      shortMessage: redact(error.shortMessage),
      details: fields.details ? redact(fields.details).slice(0, MAX_DETAIL) : undefined,
      status: fields.status,
      code: fields.code,
      host: fields.url ? rpcHost(fields.url) : undefined,
    }
  }
  if (error instanceof Error) return { name: error.name, shortMessage: redact(error.message).slice(0, MAX_DETAIL) }
  return { name: 'Error', shortMessage: redact(String(error)).slice(0, MAX_DETAIL) }
}

/** viem nests the useful facts (status, details, url) on causes. Walk the chain once. */
function findFields(error: BaseError): { details?: string; status?: number; code?: number; url?: string } {
  const out: { details?: string; status?: number; code?: number; url?: string } = {}
  let current: unknown = error
  for (let depth = 0; depth < 8 && current; depth++) {
    const e = current as { details?: unknown; status?: unknown; code?: unknown; url?: unknown; cause?: unknown }
    if (out.details === undefined && typeof e.details === 'string' && e.details) out.details = e.details
    if (out.status === undefined && typeof e.status === 'number') out.status = e.status
    if (out.code === undefined && typeof e.code === 'number') out.code = e.code
    if (out.url === undefined && typeof e.url === 'string') out.url = e.url
    current = e.cause
  }
  return out
}
