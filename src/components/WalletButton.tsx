import { useState } from 'react'
import { LogOut, Wallet, TriangleAlert, Loader2 } from 'lucide-react'
import { useWalletGate } from '@/hooks/useWalletGate'
import { shortAddress } from '@/lib/money'
import { PLUG } from '@/plug.config'

export function WalletButton() {
  const gate = useWalletGate()
  const [open, setOpen] = useState(false)

  if (!gate.isConnected) {
    if (!gate.hasInjectedWallet) {
      return (
        <a className="btn btn-primary" href="https://metamask.io/download/" target="_blank" rel="noreferrer">
          <Wallet className="size-4" /> Get a wallet
        </a>
      )
    }
    return (
      <button className="btn btn-primary" onClick={gate.connect} disabled={gate.isConnecting}>
        {gate.isConnecting ? <Loader2 className="size-4 animate-spin" /> : <Wallet className="size-4" />}
        {gate.isConnecting ? 'Connecting' : 'Connect wallet'}
      </button>
    )
  }

  if (gate.wrongNetwork) {
    return (
      <button className="btn btn-danger" onClick={gate.switchNetwork} disabled={gate.switchPending}>
        {gate.switchPending ? <Loader2 className="size-4 animate-spin" /> : <TriangleAlert className="size-4" />}
        Switch to {PLUG.chainName}
      </button>
    )
  }

  return (
    <div className="relative">
      <button className="btn btn-ghost mono" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="size-2 rounded-full" style={{ background: 'var(--success)' }} />
        {shortAddress(gate.address ?? '')}
      </button>
      {open && (
        <div className="card absolute right-0 top-12 z-40 w-48 p-2" style={{ background: 'var(--surface-muted)' }}>
          <button
            className="btn btn-ghost w-full"
            onClick={() => {
              gate.disconnect()
              setOpen(false)
            }}
          >
            <LogOut className="size-4" /> Disconnect
          </button>
        </div>
      )}
    </div>
  )
}
