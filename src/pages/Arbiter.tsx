import { useMemo } from 'react'
import { Scale } from 'lucide-react'
import { EmptyState, InfoNote, Page, PageTitle, Skeleton } from '@/components/ui'
import { OrderCard } from '@/components/OrderCard'
import { useCampaigns } from '@/hooks/useCampaigns'
import { useOrders, usePlugLogs } from '@/hooks/useOrders'
import { useWalletGate } from '@/hooks/useWalletGate'
import { sameAddress } from '@/lib/money'
import { campaignOf, STATUS } from '@/lib/orders'

/** /arbiter: contested orders on campaigns where the connected wallet is the arbiter. */
export default function Arbiter() {
  const gate = useWalletGate()
  const { orders, isLoading } = useOrders()
  const { campaigns, isLoading: loadingCampaigns } = useCampaigns()
  const { logs } = usePlugLogs()

  const myCampaignIds = useMemo(
    () => new Set(campaigns.filter((c) => sameAddress(c.arbiter, gate.address)).map((c) => c.id.toString())),
    [campaigns, gate.address],
  )
  const contested = useMemo(
    () => orders.filter((o) => myCampaignIds.has(o.campaignId.toString()) && o.status === STATUS.Contested),
    [orders, myCampaignIds],
  )

  return (
    <Page>
      <PageTitle
        title="Arbiter"
        subtitle="When a seller contests a buyer's dispute, the campaign's arbiter decides: refund the buyer or release to the seller. You have until the deadline, then the buyer can claim a refund."
      />
      {!gate.isConnected ? (
        <InfoNote>Connect the wallet that was named as arbiter on a campaign.</InfoNote>
      ) : isLoading || loadingCampaigns ? (
        <Skeleton className="h-60 !rounded-3xl" />
      ) : myCampaignIds.size === 0 ? (
        <EmptyState title="You are not an arbiter on any campaign" body="Sellers name an arbiter when they create a protected campaign. Campaigns that name this wallet will appear here." />
      ) : contested.length === 0 ? (
        <EmptyState title="Nothing to decide" body={`You are the arbiter on ${myCampaignIds.size} campaign${myCampaignIds.size === 1 ? '' : 's'}. Contested orders will appear here.`} />
      ) : (
        <div className="space-y-4">
          <p className="flex items-center gap-2 text-sm" style={{ color: 'var(--muted)' }}><Scale className="size-4" /> {contested.length} order{contested.length === 1 ? '' : 's'} waiting for your decision</p>
          {contested.map((o) => <OrderCard key={o.id.toString()} order={o} campaign={campaignOf(campaigns, o)} logs={logs} role="arbiter" compact />)}
        </div>
      )}
    </Page>
  )
}
