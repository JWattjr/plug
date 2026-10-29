import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { erc20Abi, isAddress, parseEventLogs } from 'viem'
import { ArrowRight, Check, ShieldCheck } from 'lucide-react'
import { ErrorNote, InfoNote, Page, PageTitle, Spinner, Step, TxNotice, type StepStatus } from '@/components/ui'
import { MyCampaigns } from '@/components/MyCampaigns'
import { useTx } from '@/hooks/useTx'
import { useUsdcAllowance, useUsdcBalance } from '@/hooks/useUsdc'
import { useWalletGate } from '@/hooks/useWalletGate'
import { commissionFor, fmtNumber, fmtUsdc, parseUsdcInput, sameAddress } from '@/lib/money'
import { plugAbi } from '@/lib/plugAbi'
import { WINDOW_CHOICES_DAYS } from '@/lib/orders'
import { nowSeconds } from '@/lib/time'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'

const MAX_TITLE_BYTES = 128
const MAX_URL_BYTES = 512
const byteLength = (s: string) => new TextEncoder().encode(s).length

interface FormState {
  title: string
  offerUrl: string
  price: string
  commissionPct: string
  budget: string
  days: string
  protect: boolean
  windowDays: number
  arbiter: string
}

const INITIAL: FormState = { title: '', offerUrl: '', price: '', commissionPct: '10', budget: '', days: '7', protect: false, windowDays: 7, arbiter: '' }

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

function Field({ label, hint, error, children }: { label: string; hint?: string; error?: string; children: React.ReactNode }) {
  return (
    <div>
      <label className="label">{label}</label>
      {children}
      {error ? (
        <p className="mt-1.5 text-xs" style={{ color: 'var(--danger)' }}>{error}</p>
      ) : hint ? (
        <p className="mt-1.5 text-xs" style={{ color: 'var(--subtle)' }}>{hint}</p>
      ) : null}
    </div>
  )
}

const decimalOnly = (value: string) => (/^\d*\.?\d*$/.test(value) ? value : null)

export default function Advertise() {
  const gate = useWalletGate()
  const balance = useUsdcBalance(gate.address)
  const allowance = useUsdcAllowance(gate.address)
  const approveTx = useTx()
  const createTx = useTx()
  const [form, setForm] = useState<FormState>(INITIAL)
  const [touched, setTouched] = useState(false)
  const [approvedAmount, setApprovedAmount] = useState(0n)
  const [createdId, setCreatedId] = useState<bigint | null>(null)

  const set = (key: 'title' | 'offerUrl' | 'price' | 'commissionPct' | 'budget' | 'days' | 'arbiter') => (value: string) => setForm((f) => ({ ...f, [key]: value }))

  const parsed = useMemo(() => {
    const price = parseUsdcInput(form.price)
    const budget = form.budget.trim() === '' ? undefined : parseUsdcInput(form.budget)
    const pct = form.commissionPct.trim() === '' ? NaN : Number(form.commissionPct)
    const bps = Number.isFinite(pct) ? Math.round(pct * 100) : NaN
    const days = Number(form.days)
    return { price, budget, bps, days, pct }
  }, [form])

  const errors: Partial<Record<'title' | 'offerUrl' | 'price' | 'commissionPct' | 'budget' | 'days' | 'arbiter', string>> = {}
  if (!form.title.trim()) errors.title = 'Give the offer a title.'
  else if (byteLength(form.title) > MAX_TITLE_BYTES) errors.title = `Keep the title under ${MAX_TITLE_BYTES} bytes.`
  if (!/^https?:\/\/\S+\.\S+/.test(form.offerUrl.trim())) errors.offerUrl = 'Enter a full link starting with https://'
  else if (byteLength(form.offerUrl.trim()) > MAX_URL_BYTES) errors.offerUrl = `Keep the link under ${MAX_URL_BYTES} bytes.`
  if (parsed.price === undefined || parsed.price <= 0n) errors.price = 'Enter a price above 0 (up to 6 decimals).'
  if (!Number.isFinite(parsed.pct) || parsed.pct < 0 || parsed.pct > 50 || !Number.isFinite(parsed.bps)) errors.commissionPct = 'Commission must be between 0% and 50%.'
  if (parsed.budget === undefined) errors.budget = 'Enter a budget (0 is allowed).'
  if (!Number.isInteger(parsed.days) || parsed.days < 1 || parsed.days > 365) errors.days = 'Choose 1 to 365 days.'
  if (form.protect) {
    const arbiter = form.arbiter.trim()
    if (!isAddress(arbiter)) errors.arbiter = 'Enter the arbiter\'s wallet address (0x…).'
    else if (arbiter.toLowerCase() === ZERO_ADDRESS) errors.arbiter = 'The arbiter cannot be the zero address.'
    else if (sameAddress(arbiter, gate.address)) errors.arbiter = 'The arbiter cannot be you. Pick someone buyers can trust to be fair.'
  }

  const budget = parsed.budget ?? 0n
  const haveBalance = balance.data
  const insufficient = haveBalance !== undefined && budget > haveBalance
  const valid = Object.keys(errors).length === 0 && !insufficient
  const effectiveAllowance = (allowance.data ?? 0n) > approvedAmount ? (allowance.data ?? 0n) : approvedAmount
  const needsApproval = budget > 0n && effectiveAllowance < budget

  const perSaleCommission = parsed.price !== undefined && Number.isFinite(parsed.bps) ? commissionFor(parsed.price, parsed.bps) : 0n
  const salesCovered = perSaleCommission > 0n ? budget / perSaleCommission : undefined

  async function approve() {
    setTouched(true)
    if (!valid || !PLUG.usdcAddress || !PLUG.address) return
    const receipt = await approveTx.run(() =>
      approveTx.writeContractAsync({ address: PLUG.usdcAddress!, abi: erc20Abi, functionName: 'approve', args: [PLUG.address!, budget], chainId: PLUG.chainId }),
    )
    if (receipt) setApprovedAmount(budget)
  }

  async function create() {
    setTouched(true)
    if (!valid || parsed.price === undefined || !PLUG.address) return
    const endTime = BigInt(nowSeconds() + parsed.days * 86_400)
    const receipt = await createTx.run(() =>
      createTx.writeContractAsync({
        address: PLUG.address!,
        abi: plugAbi,
        functionName: 'createCampaign',
        args: [
          form.title.trim(),
          form.offerUrl.trim(),
          parsed.price!,
          parsed.bps,
          budget,
          endTime,
          form.protect ? BigInt(form.windowDays * 86_400) : 0n,
          form.protect ? (form.arbiter.trim() as `0x${string}`) : ZERO_ADDRESS,
        ],
        chainId: PLUG.chainId,
      }),
    )
    if (receipt) {
      const [event] = parseEventLogs({ abi: plugAbi, logs: receipt.logs, eventName: 'CampaignCreated' })
      setCreatedId(event?.args.id ?? null)
      setForm(INITIAL)
      setTouched(false)
      setApprovedAmount(0n)
    }
  }

  const approveStatus: StepStatus = !needsApproval ? 'done' : approveTx.busy ? 'active' : 'active'
  const createStatus: StepStatus = needsApproval ? 'todo' : 'active'
  const busy = approveTx.busy || createTx.busy

  let action: React.ReactNode
  if (!gate.isConnected) {
    action = <button className="btn btn-primary w-full" onClick={gate.connect}>Connect wallet to continue</button>
  } else if (gate.wrongNetwork) {
    action = <button className="btn btn-primary w-full" onClick={gate.switchNetwork}>Switch to {PLUG.chainName}</button>
  } else if (needsApproval) {
    action = (
      <button className="btn btn-primary w-full" disabled={busy || (touched && !valid)} onClick={() => void approve()}>
        {approveTx.busy ? <Spinner /> : null} Step 1 of 2: Allow {fmtUsdc(budget)}
      </button>
    )
  } else {
    action = (
      <button className="btn btn-primary w-full" disabled={busy || (touched && !valid)} onClick={() => void create()}>
        {createTx.busy ? <Spinner /> : null} {budget > 0n ? 'Step 2 of 2: ' : ''}Create campaign
      </button>
    )
  }

  return (
    <Page>
      <PageTitle
        title="Advertise"
        subtitle="Lock a USDC budget, set what each sale pays the agent, and only pay when a real purchase settles. You are the seller, so buyers pay you directly."
      />
      {!PLUG_CONFIGURED && <div className="mb-6"><ErrorNote>Plug is not configured for {PLUG.chainName}. Set the contract address and deploy block.</ErrorNote></div>}

      <div className="grid gap-6 lg:grid-cols-[1.3fr_1fr]">
        <section className="card space-y-5 p-6 sm:p-7" aria-label="Create a campaign">
          <h2 className="display text-xl font-semibold">New campaign</h2>

          <Field label="Title" error={touched ? errors.title : undefined}>
            <input className="field" placeholder="Noise-cancelling headphones" value={form.title} onChange={(e) => set('title')(e.target.value)} maxLength={140} />
          </Field>
          <Field label="Offer URL" error={touched ? errors.offerUrl : undefined} hint="Where the buyer gets what they paid for.">
            <input className="field" placeholder="https://yourstore.com/headphones" inputMode="url" value={form.offerUrl} onChange={(e) => set('offerUrl')(e.target.value)} />
          </Field>

          <div className="grid gap-5 sm:grid-cols-2">
            <Field label="Price (USDC)" error={touched ? errors.price : undefined}>
              <input className="field tabular-nums" placeholder="25.00" inputMode="decimal" value={form.price} onChange={(e) => { const v = decimalOnly(e.target.value); if (v !== null) set('price')(v) }} />
            </Field>
            <Field label="Commission (%)" error={touched ? errors.commissionPct : undefined} hint="Paid to the agent per sale. Max 50%.">
              <input className="field tabular-nums" placeholder="10" inputMode="decimal" value={form.commissionPct} onChange={(e) => { const v = decimalOnly(e.target.value); if (v !== null) set('commissionPct')(v) }} />
            </Field>
            <Field label="Budget (USDC)" error={touched ? errors.budget : undefined} hint="Locked now. Unspent budget returns when you end the campaign.">
              <input className="field tabular-nums" placeholder="100.00" inputMode="decimal" value={form.budget} onChange={(e) => { const v = decimalOnly(e.target.value); if (v !== null) set('budget')(v) }} />
            </Field>
            <Field label="Duration (days)" error={touched ? errors.days : undefined}>
              <input className="field tabular-nums" placeholder="7" inputMode="numeric" value={form.days} onChange={(e) => { if (/^\d*$/.test(e.target.value)) set('days')(e.target.value) }} />
            </Field>
          </div>

          <div className="inner space-y-4 p-4" data-testid="protection-section">
            <label className="flex cursor-pointer items-start gap-3">
              <input
                type="checkbox"
                className="mt-1 size-5 accent-[color:var(--accent)]"
                checked={form.protect}
                onChange={(e) => setForm((f) => ({ ...f, protect: e.target.checked }))}
                data-testid="protect-toggle"
              />
              <span>
                <span className="flex items-center gap-1.5 text-sm font-semibold"><ShieldCheck className="size-4" style={{ color: 'var(--success)' }} /> Buyer protection</span>
                <span className="mt-0.5 block text-xs" style={{ color: 'var(--subtle)' }}>
                  Hold each buyer&apos;s payment in escrow for a window. Agents can buy with confidence, and commission is paid only on sales that stick.
                </span>
              </span>
            </label>
            {form.protect && (
              <div className="space-y-4">
                <div>
                  <span className="label">Protection window</span>
                  <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="Protection window">
                    {WINDOW_CHOICES_DAYS.map((d) => (
                      <button
                        key={d}
                        type="button"
                        role="radio"
                        aria-checked={form.windowDays === d}
                        className={`btn ${form.windowDays === d ? 'btn-primary' : 'btn-ghost'} !min-h-10`}
                        onClick={() => setForm((f) => ({ ...f, windowDays: d }))}
                        data-testid={`window-${d}`}
                      >
                        {d} days
                      </button>
                    ))}
                  </div>
                </div>
                <Field label="Arbiter address" error={touched ? errors.arbiter : undefined} hint="Public on the offer. Agents judge it before they recommend you.">
                  <input className="field mono !text-sm" placeholder="0x…" value={form.arbiter} onChange={(e) => set('arbiter')(e.target.value)} data-testid="arbiter-input" />
                </Field>
                <ul className="space-y-1.5 text-xs" style={{ color: 'var(--muted)' }}>
                  <li>Buyers can dispute during the window. If you ignore a dispute for 3 days, the buyer gets a refund.</li>
                  <li>If you contest it, the arbiter decides: refund the buyer or pay you. If the arbiter stays silent for 14 days, the buyer can claim a refund.</li>
                  <li>The arbiter never receives funds and cannot be you. Choose someone independent.</li>
                  <li>A refunded sale pays the agent nothing.</li>
                </ul>
              </div>
            )}
          </div>

          {parsed.price !== undefined && parsed.price > 0n && Number.isFinite(parsed.bps) && (
            <InfoNote>
              Each sale pays you {fmtUsdc(parsed.price)} and pays the referring agent {fmtUsdc(perSaleCommission)} from your budget.
              {salesCovered !== undefined && budget > 0n && <> Your budget covers about {salesCovered.toString()} commissioned sales.</>}
            </InfoNote>
          )}
          {gate.isConnected && haveBalance !== undefined && (
            <p className="text-xs tabular-nums" style={{ color: insufficient ? 'var(--danger)' : 'var(--subtle)' }}>
              {insufficient ? `Insufficient USDC. You have ${fmtUsdc(haveBalance)} and need ${fmtUsdc(budget)}.` : `Your balance: ${fmtUsdc(haveBalance)}`}
            </p>
          )}

          <ol className="space-y-3">
            <Step index={1} title="Allow USDC" status={budget === 0n ? 'done' : approveStatus} detail={budget === 0n ? 'Not needed for a zero budget' : needsApproval ? `Lets Plug lock ${fmtUsdc(budget)}` : 'Allowed'} />
            <Step index={2} title="Create campaign" status={createStatus} detail="Locks your budget and publishes the offer" />
          </ol>

          {action}
          <TxNotice state={approveTx.state} />
          <TxNotice state={createTx.state} />

          {createdId !== null && createTx.state.status === 'success' && (
            <div className="inner flex flex-wrap items-center justify-between gap-3 p-4">
              <p className="flex items-center gap-2 text-sm font-semibold" style={{ color: 'var(--success)' }}>
                <Check className="size-4" /> Campaign #{createdId.toString()} is live
              </p>
              <Link className="btn btn-ghost" to={`/checkout/${createdId.toString()}`}>View offer <ArrowRight className="size-4" /></Link>
            </div>
          )}
        </section>

        <aside className="space-y-4">
          <div className="card p-6">
            <h3 className="display text-lg font-semibold">How you stay safe</h3>
            <ul className="mt-3 space-y-2 text-sm" style={{ color: 'var(--muted)' }}>
              <li>Commission is paid only on a settled purchase. Clicks pay nothing.</li>
              <li>If you buy from yourself, you only move your own USDC.</li>
              <li>Anyone else pays you the full price to earn back at most half.</li>
              <li>End the campaign any time to get unspent budget back.</li>
              <li>Turn on buyer protection so agents can buy for their users with confidence. Protected sales pay you after the window.</li>
            </ul>
          </div>
          <p className="px-1 text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
            Preview: {parsed.price ? fmtNumber(parsed.price) : '0.00'} USDC price, {form.commissionPct || '0'}% commission, {form.days || '0'} days.
          </p>
        </aside>
      </div>

      <MyCampaigns />
    </Page>
  )
}
