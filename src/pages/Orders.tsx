import { useMemo } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ArrowLeft } from 'lucide-react'
import { EmptyState, ErrorNote, InfoNote, Page, PageTitle, Skeleton } from '@/components/ui'
import { OrderCard, type OrderRole } from '@/components/OrderCard'
import { useCampaigns } from '@/hooks/useCampaigns'
import { useOrders, usePlugLogs } from '@/hooks/useOrders'
import { useWalletGate } from '@/hooks/useWalletGate'
import { sameAddress } from '@/lib/money'
import { campaignOf, isOpen } from '@/lib/orders'
import { PLUG_CONFIGURED } from '@/plug.config'

/** /orders: the connected buyer's protected orders. */
export function OrdersPage() {
  const gate = useWalletGate()
  const { orders, isLoading, error } = useOrders()
  const { campaigns } = useCampaigns()
  const { logs } = usePlugLogs()
  const mine = useMemo(() => orders.filter((o) => sameAddress(o.buyer, gate.address)), [orders, gate.address])
  const open = mine.filter(isOpen)
  const done = mine.filter((o) => !isOpen(o))

  return (
    <Page>
      <PageTitle
        title="My orders"
        subtitle="Protected purchases are held in escrow. Confirm when it arrives, dispute if something is wrong, or let the window pass and the seller is paid."
      />
      {!PLUG_CONFIGURED && <ErrorNote>Plug is not configured for this network.</ErrorNote>}
      {error && <ErrorNote>Could not read orders from the chain. Retrying.</ErrorNote>}
      {!gate.isConnected ? (
        <InfoNote>Connect your wallet to see your orders.</InfoNote>
      ) : isLoading ? (
        <div className="space-y-4">{[0, 1].map((i) => <Skeleton key={i} className="h-60 !rounded-3xl" />)}</div>
      ) : mine.length === 0 ? (
        <EmptyState
          title="No protected orders yet"
          body="When you buy a protected offer, it shows up here with a live status timeline. Instant offers pay the seller straight away and have no order."
          action={<Link to="/offers" className="btn btn-primary">Browse offers</Link>}
        />
      ) : (
        <div className="space-y-8">
          {open.length > 0 && (
            <section className="space-y-4" aria-label="Open orders">
              <h2 className="display text-xl font-semibold">In progress</h2>
              {open.map((o) => <OrderCard key={o.id.toString()} order={o} campaign={campaignOf(campaigns, o)} logs={logs} role="buyer" />)}
            </section>
          )}
          {done.length > 0 && (
            <section className="space-y-4" aria-label="Finished orders">
              <h2 className="display text-xl font-semibold">Finished</h2>
              {done.map((o) => <OrderCard key={o.id.toString()} order={o} campaign={campaignOf(campaigns, o)} logs={logs} role="buyer" />)}
            </section>
          )}
        </div>
      )}
    </Page>
  )
}

/** /orders/:id: one order. The buttons you see depend on who you are connected as. */
export function OrderPage() {
  const params = useParams()
  const id = params.id && /^\d+$/.test(params.id) ? BigInt(params.id) : undefined
  const gate = useWalletGate()
  const { orders, isLoading } = useOrders()
  const { campaigns } = useCampaigns()
  const { logs } = usePlugLogs()
  const order = orders.find((o) => o.id === id)
  const campaign = order ? campaignOf(campaigns, order) : undefined

  let role: OrderRole = 'viewer'
  if (order && campaign) {
    if (sameAddress(order.buyer, gate.address)) role = 'buyer'
    else if (sameAddress(campaign.advertiser, gate.address)) role = 'seller'
    else if (sameAddress(campaign.arbiter, gate.address)) role = 'arbiter'
  }
  const hasRole =
    Boolean(order && gate.address) &&
    (sameAddress(order?.buyer, gate.address) || sameAddress(campaign?.advertiser, gate.address) || sameAddress(campaign?.arbiter, gate.address))

  return (
    <Page narrow>
      <Link to="/orders" className="mb-6 inline-flex items-center gap-1 text-sm" style={{ color: 'var(--muted)' }}>
        <ArrowLeft className="size-4" /> All orders
      </Link>
      {id === undefined ? (
        <ErrorNote>That is not a valid order link.</ErrorNote>
      ) : isLoading ? (
        <Skeleton className="h-80 !rounded-3xl" />
      ) : !order ? (
        <ErrorNote>Order #{id.toString()} does not exist on this network.</ErrorNote>
      ) : (
        <div className="space-y-4">
          {!hasRole && <InfoNote>You are viewing this order read-only. Connect the buyer, seller or arbiter wallet to act on it.</InfoNote>}
          <OrderCard order={order} campaign={campaign} logs={logs} role={role} />
        </div>
      )}
    </Page>
  )
}
