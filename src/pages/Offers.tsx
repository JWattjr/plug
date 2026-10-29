import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Check, Copy } from 'lucide-react'
import { EmptyState, ErrorNote, Page, PageTitle, Skeleton } from '@/components/ui'
import { OfferCard } from '@/components/OfferCard'
import { useLiveOffers } from '@/hooks/useCampaigns'
import { escapeForScriptTag, toOfferJson, type Campaign } from '@/lib/campaigns'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'

function CopyButton({ text, label }: { text: string; label: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      className="btn btn-ghost !min-h-9 !px-3 text-xs"
      onClick={() => {
        navigator.clipboard.writeText(text).then(
          () => {
            setCopied(true)
            setTimeout(() => setCopied(false), 1500)
          },
          () => setCopied(false),
        )
      }}
    >
      {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />} {copied ? 'Copied' : label}
    </button>
  )
}

function ForAgents({ offers }: { offers: Campaign[] }) {
  const json = JSON.stringify(
    {
      protocol: 'plug',
      sponsored: true,
      disclosure: 'Every offer is sponsored. State that before recommending.',
      chainId: PLUG.chainId,
      contract: PLUG.address,
      usdc: PLUG.usdcAddress,
      offers: offers.map(toOfferJson),
    },
    null,
    2,
  )

  return (
    <section className="card mt-12 p-6 sm:p-8" aria-labelledby="for-agents">
      <h2 id="for-agents" className="display text-2xl font-semibold">For agents</h2>
      <p className="mt-2 max-w-2xl text-pretty text-sm" style={{ color: 'var(--muted)' }}>
        Read offers straight from the contract, tell the buyer the offer is sponsored, then send them to settle with your payout address as the referrer.
      </p>

      <dl className="mt-6 grid gap-3 text-sm sm:grid-cols-2">
        <div className="inner p-4">
          <dt className="label">Contract ({PLUG.chainName}, chain {PLUG.chainId})</dt>
          <dd className="flex flex-wrap items-center justify-between gap-2">
            <code className="mono break-all text-xs" data-testid="contract-address">{PLUG.address ?? 'Not configured'}</code>
            {PLUG.address && <CopyButton text={PLUG.address} label="Copy" />}
          </dd>
        </div>
        <div className="inner p-4">
          <dt className="label">USDC (6 decimals)</dt>
          <dd><code className="mono break-all text-xs">{PLUG.usdcAddress}</code></dd>
        </div>
        <div className="inner p-4">
          <dt className="label">1. Read offers</dt>
          <dd className="space-y-1">
            <code className="mono block text-xs">campaignCount() returns (uint256)</code>
            <code className="mono block text-xs">getCampaign(uint256 id) returns (Campaign)</code>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>An offer is live when active is true and endTime is in the future.</p>
          </dd>
        </div>
        <div className="inner p-4">
          <dt className="label">2. Settle a sale</dt>
          <dd className="space-y-1">
            <code className="mono block text-xs">buy(uint256 id, address referrer) returns (uint256 orderId)</code>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>
              The buyer first approves the price in USDC. Instant offers pay the seller and your commission in the same transaction. Protected offers hold the payment: the returned orderId tracks it, and your commission is paid when the order releases.
            </p>
          </dd>
        </div>
        <div className="inner p-4 sm:col-span-2">
          <dt className="label">3. Protected offers (protectionWindow &gt; 0)</dt>
          <dd className="space-y-1">
            <code className="mono block text-xs">getOrder(uint256 orderId) returns (Order)</code>
            <code className="mono block text-xs">confirm(orderId) · dispute(orderId, reason) · claimRefund(orderId) · claimOwedRefund(orderId)</code>
            <p className="text-xs" style={{ color: 'var(--subtle)' }}>
              Judge the arbiter before you recommend: the seller names it and it is public on every offer. A refunded sale pays you no commission, and the arbiter can never receive funds.
            </p>
          </dd>
        </div>
      </dl>

      <div className="mt-6">
        <div className="mb-2 flex items-center justify-between">
          <h3 className="label !mb-0">Live offers as JSON</h3>
          <CopyButton text={json} label="Copy JSON" />
        </div>
        <pre className="inner mono max-h-80 overflow-auto p-4 text-xs leading-relaxed" tabIndex={0} aria-label="Offers JSON">{json}</pre>
        <script id="plug-offers" type="application/json" dangerouslySetInnerHTML={{ __html: escapeForScriptTag(json) }} />
      </div>
    </section>
  )
}

export default function Offers() {
  const { offers, isLoading, error, now } = useLiveOffers()

  return (
    <Page>
      <PageTitle
        title="Live offers"
        subtitle="Every offer here is sponsored: the seller pays agents a commission when they refer a sale. You pay the same price either way."
      />

      {!PLUG_CONFIGURED && <ErrorNote>Plug is not configured for {PLUG.chainName}. Set the contract address and deploy block.</ErrorNote>}
      {error && <ErrorNote>Could not read campaigns from the chain. Retrying.</ErrorNote>}

      {isLoading ? (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {[0, 1, 2].map((i) => <Skeleton key={i} className="h-72 !rounded-3xl" />)}
        </div>
      ) : offers.length === 0 ? (
        <EmptyState
          title="No live offers yet"
          body="Offers appear here the moment a seller creates a campaign. Be the first."
          action={<Link to="/advertise" className="btn btn-primary">Create a campaign</Link>}
        />
      ) : (
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {offers.map((c, i) => <OfferCard key={c.id.toString()} campaign={c} now={now} index={i} />)}
        </div>
      )}

      <ForAgents offers={offers} />
    </Page>
  )
}
