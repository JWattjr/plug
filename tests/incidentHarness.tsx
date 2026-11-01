import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider, createConfig, custom } from 'wagmi'
import { connect, disconnect } from 'wagmi/actions'
import { injected } from 'wagmi/connectors'
import { arc } from 'viem/chains'
import App from '../src/App'
import { allowanceTransports, resetAllowanceClients } from '../src/hooks/useUsdc'
import { clearReadLog } from '../src/lib/readLog'
import { READ_TIMING, resilientTransport } from '../src/lib/readTransport'
import { bindWalletReads } from '../src/lib/walletReads'
import { PLUG } from '../src/plug.config'
import type { FakeChain } from './fakeChain'

/** The real app (router, layout, pages, hooks, read transport) over a fake chain and a scripted wallet. */
export interface Mounted {
  chain: FakeChain
  container: HTMLElement
  config: ReturnType<typeof makeConfig>
  root: Root
  queryClient: QueryClient
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

export function makeConfig(chain: FakeChain) {
  const config = createConfig({
    chains: [arc],
    connectors: [injected({ target: { id: 'fake', name: 'Fake wallet', provider: chain.wallet as never } })],
    // The same transport the app ships: public endpoints first, then the connected wallet's read-only connection.
    transports: {
      [arc.id]: resilientTransport({ chainId: arc.id, urls: PLUG.rpcUrls, http: custom({ request: chain.rpc as never }, { retryCount: 0 }) }),
    },
    storage: null,
  })
  bindWalletReads(config)
  return config
}

export function resetEnvironment(chain: FakeChain) {
  READ_TIMING.httpBudgetMs = 300
  READ_TIMING.walletTimeoutMs = 2_000
  allowanceTransports.http = () => custom({ request: chain.rpc as never }, { retryCount: 0 })
  resetAllowanceClients()
  clearReadLog()
}

export async function mountApp(chain: FakeChain, path: string, options: { connected?: boolean; afterConnect?: () => void } = {}): Promise<Mounted> {
  const config = makeConfig(chain)
  if (options.connected !== false) await connect(config, { connector: config.connectors[0], chainId: arc.id })
  // Connecting is the user's explicit act. Everything the wallet is asked after it is what the app does on its own.
  chain.walletLog.length = 0
  options.afterConnect?.()
  window.history.pushState({}, '', path)
  const queryClient = new QueryClient({ defaultOptions: { queries: { retryDelay: 1 } } })
  const container = document.createElement('div')
  document.body.appendChild(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(
      <WagmiProvider config={config} reconnectOnMount={false}>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </WagmiProvider>,
    )
  })
  return { chain, container, config, root, queryClient }
}

export async function unmountApp(m: Mounted) {
  await act(async () => {
    m.root.unmount()
  })
  m.queryClient.clear()
  m.container.remove()
}

export async function disconnectWallet(m: Mounted) {
  await act(async () => {
    await disconnect(m.config)
  })
}

export const textOf = (m: Mounted) => m.container.textContent ?? ''

export function buttonsOf(m: Mounted): string[] {
  return Array.from(m.container.querySelectorAll('button')).map((b) => b.textContent?.trim() ?? '')
}

export async function typeInto(m: Mounted, placeholder: string, value: string) {
  await until(m, () => m.container.querySelector(`input[placeholder="${placeholder}"]`) !== null, `input ${placeholder}`)
  const input = m.container.querySelector(`input[placeholder="${placeholder}"]`) as HTMLInputElement
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(input, value)
    input.dispatchEvent(new Event('input', { bubbles: true }))
  })
}

/** The incident form: title NCH, 0.01 USDC price, 20% commission, 0.01 USDC budget. */
export async function fillCampaignForm(m: Mounted) {
  await typeInto(m, 'Noise-cancelling headphones', 'NCH')
  await typeInto(m, 'https://yourstore.com/headphones', 'http://yourstore.com/headphones')
  await typeInto(m, '25.00', '0.01')
  await typeInto(m, '10', '20')
  await typeInto(m, '100.00', '0.01')
}

export async function click(m: Mounted, label: RegExp) {
  const button = Array.from(m.container.querySelectorAll('button')).find((b) => label.test((b.textContent ?? '').trim()) && !b.disabled)
  if (!button) throw new Error(`no enabled button matching ${label}; have ${JSON.stringify(buttonsOf(m))}`)
  await act(async () => {
    button.click()
  })
}

export async function until(m: Mounted, check: () => boolean, what: string, timeoutMs = 6000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (check()) return
    await act(async () => {
      await sleep(25)
    })
  }
  throw new Error(`timed out waiting for: ${what}. Buttons: ${JSON.stringify(buttonsOf(m))}. Text: ${textOf(m).replace(/\s+/g, ' ').slice(0, 900)}`)
}
