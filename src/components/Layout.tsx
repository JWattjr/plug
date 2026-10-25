import { useState } from 'react'
import { Link, NavLink, Outlet, useLocation } from 'react-router-dom'
import { Menu, PlugZap, TriangleAlert, X } from 'lucide-react'
import { AnimatePresence, motion } from 'framer-motion'
import { WalletButton } from '@/components/WalletButton'
import { useWalletGate } from '@/hooks/useWalletGate'
import { PLUG, PLUG_CONFIGURED } from '@/plug.config'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { shortAddress } from '@/lib/money'

const LINKS = [
  { to: '/advertise', label: 'Advertise' },
  { to: '/offers', label: 'Offers' },
  { to: '/agent', label: 'Demo agent' },
]

function NetworkBanner() {
  const gate = useWalletGate()
  if (!PLUG_CONFIGURED) {
    return (
      <Banner>
        Plug is not configured for {PLUG.chainName} yet. Set VITE_PLUG_ADDRESS and VITE_PLUG_DEPLOY_BLOCK.
      </Banner>
    )
  }
  if (gate.wrongNetwork) {
    return (
      <Banner>
        Your wallet is on the wrong network. Plug runs on {PLUG.chainName}.{' '}
        <button className="underline underline-offset-2" onClick={gate.switchNetwork}>
          Switch network
        </button>
      </Banner>
    )
  }
  return null
}

function Banner({ children }: { children: React.ReactNode }) {
  return (
    <div className="border-b px-4 py-2 text-center text-sm" style={{ background: 'rgba(239,122,134,0.12)', borderColor: 'rgba(239,122,134,0.3)', color: 'var(--danger)' }}>
      <TriangleAlert className="mr-1.5 inline size-4 align-[-3px]" />
      {children}
    </div>
  )
}

export function Layout() {
  const [menu, setMenu] = useState(false)
  const location = useLocation()
  const gate = useWalletGate()
  const earningsTarget = gate.address ?? PLUG.demoAgent
  const links = earningsTarget ? [...LINKS, { to: `/earnings/${earningsTarget}`, label: 'Earnings' }] : LINKS

  return (
    <div className="flex min-h-dvh flex-col">
      <header className="sticky top-0 z-30 border-b backdrop-blur-xl" style={{ borderColor: 'var(--border)', background: 'rgba(11,22,38,0.72)' }}>
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between gap-3 px-4">
          <Link to="/" className="flex items-center gap-2" onClick={() => setMenu(false)}>
            <span className="flex size-9 items-center justify-center rounded-xl" style={{ background: 'var(--accent)', color: 'var(--accent-ink)' }}>
              <PlugZap className="size-5" />
            </span>
            <span className="display text-xl font-bold">Plug</span>
          </Link>

          <nav className="hidden items-center gap-1 md:flex" aria-label="Main">
            {links.map((l) => (
              <NavLink
                key={l.to}
                to={l.to}
                className={({ isActive }) => `rounded-xl px-3 py-2 text-sm font-medium transition-colors ${isActive ? 'bg-white/10' : 'text-[color:var(--muted)] hover:bg-white/5'}`}
              >
                {l.label}
              </NavLink>
            ))}
          </nav>

          <div className="flex items-center gap-2">
            <span className="chip hidden sm:inline-flex">
              <span className="size-1.5 rounded-full" style={{ background: PLUG.isTestnet ? 'var(--agent)' : 'var(--success)' }} />
              {PLUG.chainName}
            </span>
            <WalletButton />
            <button className="btn btn-ghost !px-3 md:hidden" onClick={() => setMenu((v) => !v)} aria-label="Menu" aria-expanded={menu}>
              {menu ? <X className="size-5" /> : <Menu className="size-5" />}
            </button>
          </div>
        </div>
        <AnimatePresence>
          {menu && (
            <motion.nav
              initial={{ height: 0, opacity: 0 }}
              animate={{ height: 'auto', opacity: 1 }}
              exit={{ height: 0, opacity: 0 }}
              className="overflow-hidden md:hidden"
              aria-label="Mobile"
            >
              <div className="flex flex-col gap-1 px-4 pb-3">
                {links.map((l) => (
                  <NavLink key={l.to} to={l.to} onClick={() => setMenu(false)} className="rounded-xl px-3 py-3 text-sm font-medium hover:bg-white/5">
                    {l.label}
                  </NavLink>
                ))}
              </div>
            </motion.nav>
          )}
        </AnimatePresence>
      </header>

      <NetworkBanner />

      <main key={location.pathname} className="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:py-12">
        <Outlet />
      </main>

      <footer className="border-t px-4 py-8 pb-24 text-sm" style={{ borderColor: 'var(--border)', color: 'var(--subtle)' }}>
        <div className="mx-auto flex max-w-6xl flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
          <p>Every offer on Plug is sponsored. Agents must say so before they recommend one.</p>
          {PLUG.address && (
            <a className="mono underline-offset-2 hover:underline" href={buildAddressExplorerUrl(PLUG.chainId, PLUG.address)} target="_blank" rel="noreferrer">
              Contract {shortAddress(PLUG.address)}
            </a>
          )}
        </div>
      </footer>
    </div>
  )
}
