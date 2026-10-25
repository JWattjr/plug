import { useState } from 'react'
import { Link } from 'react-router-dom'
import { erc20Abi } from 'viem'
import { motion } from 'framer-motion'
import { EmptyState, InfoNote, Skeleton, Spinner, TxNotice } from '@/components/ui'
import { useCampaigns, useNow } from '@/hooks/useCampaigns'
import { useTx } from '@/hooks/useTx'
import { useUsdcAllowance, useUsdcBalance } from '@/hooks/useUsdc'
import { useWalletGate } from '@/hooks/useWalletGate'
import { isLive, type Campaign } from '@/lib/campaigns'
import { fmtBps, fmtNumber, fmtUsdc, parseUsdcInput, sameAddress } from '@/lib/money'
import { plugAbi } from '@/lib/plugAbi'
import { fmtTimeLeft } from '@/lib/time'
import { PLUG } from '@/plug.config'

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="inner p-3">
      <div className="text-[0.68rem] font-semibold uppercase tracking-[0.08em]" style={{ color: 'var(--subtle)' }}>{label}</div>
      <div className="mt-1 text-sm font-semibold tabular-nums">{value}</div>
    </div>
  )
}

function TopUp({ campaign, owner }: { campaign: Campaign; owner: `0x${string}` }) {
  const [amount, setAmount] = useState('')
  const [approved, setApproved] = useState(0n)
  const approveTx = useTx()
  const topUpTx = useTx()
  const allowance = useUsdcAllowance(owner)
  const balance = useUsdcBalance(owner)

  const raw = parseUsdcInput(amount)
  const valid = raw !== undefined && raw > 0n
  const have = (allowance.data ?? 0n) > approved ? (allowance.data ?? 0n) : approved
  const needsApproval = valid && have < raw
  const insufficient = valid && balance.data !== undefined && raw > balance.data
  const busy = approveTx.busy || topUpTx.busy

  async function approve() {
    if (!valid || !PLUG.usdcAddress || !PLUG.address) return
    const receipt = await approveTx.run(() =>
      approveTx.writeContractAsync({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'approve', args: [PLUG.address!, raw], chainId: PLUG.chainId }),
    )
    if (receipt) setApproved(raw)
  }

  async function topUp() {
    if (!valid || !PLUG.address) return
    const receipt = await topUpTx.run(() =>
      topUpTx.writeContractAsync({ address: PLUG.address!, abi: plugAbi, functionName: 'topUp', args: [campaign.id, raw], chainId: PLUG.chainId }),
    )
    if (receipt) {
      setAmount('')
      setApproved(0n)
    }
  }

  return (
    <div className="inner mt-3 space-y-3 p-4">
      <div className="flex gap-2">
        <input
          className="field tabular-nums"
          placeholder="Amount in USDC"
          inputMode="decimal"
          aria-label="Top up amount"
          value={amount}
          onChange={(e) => /^\d*\.?\d*$/.test(e.target.value) && setAmount(e.target.value)}
        />
        {needsApproval ? (
          <button className="btn btn-primary" disabled={busy || insufficient} onClick={() => void approve()}>
            {approveTx.busy && <Spinner />} Allow
          </button>
        ) : (
          <button className="btn btn-primary" disabled={!valid || busy || insufficient} onClick={() => void topUp()}>
            {topUpTx.busy && <Spinner />} Add
          </button>
        )}
      </div>
      {insufficient && <p className="text-xs" style={{ color: 'var(--danger)' }}>Insufficient USDC for that amount.</p>}
      <TxNotice state={approveTx.state} />
      <TxNotice state={topUpTx.state} />
    </div>
  )
}

function CampaignRow({ campaign, now, owner }: { campaign: Campaign; now: number; owner: `0x${string}` }) {
  const [showTopUp, setShowTopUp] = useState(false)
  const [confirmEnd, setConfirmEnd] = useState(false)
  const endTx = useTx()
  const live = isLive(campaign, now)
  const expiredOpen = campaign.active && !live

  async function end() {
    if (!PLUG.address) return
    const receipt = await endTx.run(() =>
      endTx.writeContractAsync({ address: PLUG.address!, abi: plugAbi, functionName: 'endCampaign', args: [campaign.id], chainId: PLUG.chainId }),
    )
    if (receipt) setConfirmEnd(false)
  }

  const status = live ? 'Live' : expiredOpen ? 'Expired, budget not yet returned' : 'Closed'
  const statusColor = live ? 'var(--success)' : expiredOpen ? 'var(--agent)' : 'var(--subtle)'

  return (
    <motion.li layout initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} className="card card-lift p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <Link to={`/checkout/${campaign.id.toString()}`} className="display text-lg font-semibold underline-offset-2 hover:underline">
            {campaign.title || 'Untitled offer'}
          </Link>
          <p className="mt-0.5 text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
            #{campaign.id.toString()} · {fmtUsdc(campaign.price)} · {fmtBps(campaign.commissionBps)} commission
          </p>
        </div>
        <span className="chip" style={{ color: statusColor }}>{status}</span>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Metric label="Sales" value={campaign.sales.toString()} />
        <Metric label="Commission paid" value={fmtUsdc(campaign.commissionPaid)} />
        <Metric label="Budget left" value={fmtUsdc(campaign.budgetRemaining)} />
        <Metric label="Ends in" value={fmtTimeLeft(campaign.endTime, now)} />
      </div>

      {campaign.active && (
        <div className="mt-4 flex flex-wrap gap-2">
          {live && (
            <button className="btn btn-ghost" onClick={() => setShowTopUp((v) => !v)} aria-expanded={showTopUp}>
              Top up
            </button>
          )}
          {!confirmEnd ? (
            <button className="btn btn-danger" onClick={() => setConfirmEnd(true)}>End campaign</button>
          ) : (
            <>
              <button className="btn btn-danger" disabled={endTx.busy} onClick={() => void end()}>
                {endTx.busy && <Spinner />} Confirm: end and refund {fmtNumber(campaign.budgetRemaining)} USDC
              </button>
              <button className="btn btn-ghost" disabled={endTx.busy} onClick={() => setConfirmEnd(false)}>Cancel</button>
            </>
          )}
        </div>
      )}
      {showTopUp && live && <TopUp campaign={campaign} owner={owner} />}
      <div className="mt-3"><TxNotice state={endTx.state} /></div>
    </motion.li>
  )
}

export function MyCampaigns() {
  const gate = useWalletGate()
  const { campaigns, isLoading } = useCampaigns()
  const now = useNow()
  const mine = campaigns.filter((c) => sameAddress(c.advertiser, gate.address))

  return (
    <section className="mt-14" aria-labelledby="my-campaigns">
      <h2 id="my-campaigns" className="display mb-4 text-2xl font-semibold">My campaigns</h2>
      {!gate.isConnected ? (
        <InfoNote>Connect your wallet to see and manage your campaigns.</InfoNote>
      ) : isLoading ? (
        <Skeleton className="h-40 !rounded-3xl" />
      ) : mine.length === 0 ? (
        <EmptyState title="No campaigns yet" body="Create your first campaign above. It will show up here with live sales and budget." />
      ) : (
        <ul className="space-y-4">
          {mine.map((c) => (
            <CampaignRow key={c.id.toString()} campaign={c} now={now} owner={gate.address as `0x${string}`} />
          ))}
        </ul>
      )}
    </section>
  )
}
