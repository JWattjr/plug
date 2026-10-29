import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { motion } from 'framer-motion'
import { ArrowUp, Bot, ShoppingBag, User } from 'lucide-react'
import { ErrorNote, Page, PageTitle, SponsoredBadge } from '@/components/ui'
import { ProtectionBadge } from '@/components/ProtectionBadge'
import { useLiveOffers } from '@/hooks/useCampaigns'
import { commissionPerSale, type Campaign } from '@/lib/campaigns'
import { rankOffers, SPONSOR_DISCLOSURE } from '@/lib/matcher'
import { fmtBps, fmtUsdc, shortAddress } from '@/lib/money'
import { PLUG } from '@/plug.config'

interface Message {
  id: number
  role: 'user' | 'agent'
  text: string
  /** Best match, when the agent has a recommendation. */
  offer?: Campaign
  others?: Campaign[]
}

function checkoutPath(id: bigint): string {
  const base = `/checkout/${id.toString()}`
  return PLUG.demoAgent ? `${base}?ref=${PLUG.demoAgent}` : base
}

function AgentBubble({ message }: { message: Message }) {
  const { offer, others } = message
  return (
    <div className="space-y-3">
      <p className="text-pretty text-sm leading-relaxed">
        {offer ? <strong style={{ color: 'var(--agent)' }}>{SPONSOR_DISCLOSURE}</strong> : null}
        {offer ? ' ' : ''}
        {offer ? message.text.slice(SPONSOR_DISCLOSURE.length + 1) : message.text}
      </p>
      {offer && (
        <div className="inner space-y-3 p-4">
          <div className="flex items-center justify-between gap-2">
            <SponsoredBadge />
            <span className="mono text-xs" style={{ color: 'var(--subtle)' }}>#{offer.id.toString()}</span>
          </div>
          <ProtectionBadge campaign={offer} />
          <div>
            <div className="display text-lg font-semibold">{offer.title}</div>
            <div className="text-sm tabular-nums" style={{ color: 'var(--muted)' }}>
              {fmtUsdc(offer.price)} · seller pays the agent {fmtBps(offer.commissionBps)}
            </div>
          </div>
          <Link to={checkoutPath(offer.id)} className="btn btn-primary w-full sm:w-auto">
            <ShoppingBag className="size-4" /> Buy
          </Link>
        </div>
      )}
      {others && others.length > 0 && (
        <p className="text-xs" style={{ color: 'var(--subtle)' }}>
          Also sponsored:{' '}
          {others.map((o, i) => (
            <span key={o.id.toString()}>
              {i > 0 && ', '}
              <Link className="underline underline-offset-2" to={checkoutPath(o.id)}>{o.title}</Link>
            </span>
          ))}
        </p>
      )}
    </div>
  )
}

export default function Agent() {
  const { offers, isLoading, error } = useLiveOffers()
  const [messages, setMessages] = useState<Message[]>([
    {
      id: 0,
      role: 'agent',
      text: 'Hi, I am the Plug demo shopping agent. Tell me what you need. I only know the sponsored offers listed on Plug, and I will always say so before I recommend one.',
    },
  ])
  const [input, setInput] = useState('')
  const endRef = useRef<HTMLDivElement>(null)
  const nextId = useRef(1)

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [messages])

  function ask(question: string) {
    const query = question.trim()
    if (!query) return
    const matches = rankOffers(query, offers)
    const reply: Message = { id: nextId.current + 1, role: 'agent', text: '' }

    if (matches.length === 0) {
      reply.text =
        offers.length === 0
          ? 'There are no live offers on Plug right now, so I have nothing to recommend. Check back after a seller creates a campaign.'
          : `I could not find a sponsored offer that matches "${query}". I only know the ${offers.length} live offer${offers.length === 1 ? '' : 's'} on Plug, and none of them fit. Try different words.`
    } else {
      const best = matches[0].campaign
      const commission = commissionPerSale(best)
      reply.offer = best
      reply.others = matches.slice(1, 3).map((m) => m.campaign)
      reply.text =
        `${SPONSOR_DISCLOSURE} The best match for "${query}" is "${best.title}" at ${fmtUsdc(best.price)}. ` +
        (commission > 0n
          ? `If you buy through my link, the seller pays me ${fmtUsdc(commission)} out of its own budget. You pay the same price either way.`
          : 'This seller set no commission, so I earn nothing from it. You pay the same price either way.')
    }

    setMessages((m) => [...m, { id: nextId.current, role: 'user', text: query }, reply])
    nextId.current += 2
    setInput('')
  }

  const suggestions = Array.from(new Set(offers.map((o) => o.title).filter(Boolean))).slice(0, 3)

  return (
    <Page narrow>
      <PageTitle
        title="Demo shopping agent"
        subtitle="A simple agent that matches your words to live sponsored offers. No AI model: just keyword matching, and it always discloses the sponsorship."
      />

      <div className="mb-4 flex flex-wrap items-center gap-2 text-xs" style={{ color: 'var(--subtle)' }}>
        <Bot className="size-4" />
        {PLUG.demoAgent ? (
          <span>Agent payout address <span className="mono">{shortAddress(PLUG.demoAgent)}</span></span>
        ) : (
          <span>No demo agent address configured. Set VITE_DEMO_AGENT_ADDRESS to earn commission.</span>
        )}
      </div>
      {error && <div className="mb-4"><ErrorNote>Could not read offers from the chain. Retrying.</ErrorNote></div>}

      <div className="card flex h-[60dvh] min-h-[420px] flex-col overflow-hidden">
        <div className="flex-1 space-y-5 overflow-y-auto p-5" aria-live="polite">
          {messages.map((m) => (
            <motion.div
              key={m.id}
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              className={`flex gap-3 ${m.role === 'user' ? 'flex-row-reverse' : ''}`}
            >
              <span
                className="flex size-8 shrink-0 items-center justify-center rounded-full"
                style={{ background: m.role === 'agent' ? 'rgba(240,184,107,0.15)' : 'var(--surface-strong)', color: m.role === 'agent' ? 'var(--agent)' : 'var(--ink)' }}
              >
                {m.role === 'agent' ? <Bot className="size-4" /> : <User className="size-4" />}
              </span>
              <div
                className="max-w-[85%] rounded-2xl px-4 py-3"
                style={{ background: m.role === 'agent' ? 'var(--surface)' : 'rgba(172,198,233,0.14)', border: '1px solid var(--border)' }}
              >
                {m.role === 'agent' ? <AgentBubble message={m} /> : <p className="text-sm">{m.text}</p>}
              </div>
            </motion.div>
          ))}
          <div ref={endRef} />
        </div>

        <div className="border-t p-3" style={{ borderColor: 'var(--border)' }}>
          {suggestions.length > 0 && messages.length === 1 && (
            <div className="mb-2 flex flex-wrap gap-2">
              {suggestions.map((s) => (
                <button key={s} className="chip hover:bg-white/15" onClick={() => ask(s)}>{s}</button>
              ))}
            </div>
          )}
          <form
            className="flex gap-2"
            onSubmit={(e) => {
              e.preventDefault()
              ask(input)
            }}
          >
            <input
              className="field"
              placeholder={isLoading ? 'Loading offers…' : 'What do you need?'}
              aria-label="Tell the agent what you need"
              value={input}
              disabled={isLoading}
              onChange={(e) => setInput(e.target.value)}
            />
            <button className="btn btn-primary !px-4" type="submit" disabled={isLoading || !input.trim()} aria-label="Send">
              <ArrowUp className="size-5" />
            </button>
          </form>
        </div>
      </div>
    </Page>
  )
}
