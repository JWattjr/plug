import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { act, type ReactNode } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { WagmiProvider, createConfig, custom } from 'wagmi'
import { connect, disconnect } from 'wagmi/actions'
import { injected } from 'wagmi/connectors'
import { arc } from 'viem/chains'
import { TX_TIMING } from '../src/hooks/useTx'
import Advertise from '../src/pages/Advertise'
import { FakeChain } from './fakeChain'
import { ONE_CENT, OTHER, OWNER } from './fixtures'

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

interface Harness {
  chain: FakeChain
  container: HTMLElement
  config: ReturnType<typeof makeConfig>
  root: Root
  queryClient: QueryClient
}

function makeConfig(chain: FakeChain) {
  return createConfig({
    chains: [arc],
    connectors: [injected({ target: { id: 'fake', name: 'Fake wallet', provider: chain.wallet as never } })],
    transports: { [arc.id]: custom({ request: chain.rpc as never }, { retryCount: 0 }) },
    storage: null,
  })
}

let h: Harness

async function mount(chain: FakeChain, ui: (children: ReactNode) => ReactNode = (c) => c): Promise<Harness> {
  const config = makeConfig(chain)
  await connect(config, { connector: config.connectors[0], chainId: arc.id })
  const queryClient = new QueryClient({ defaultOptions: { queries: { retryDelay: 1 } } })
  const container = document.createElement('div')
  document.body.appendChild(container)
  const root = createRoot(container)
  await act(async () => {
    root.render(
      <WagmiProvider config={config} reconnectOnMount={false}>
        <QueryClientProvider client={queryClient}>
          <MemoryRouter>{ui(<Advertise />)}</MemoryRouter>
        </QueryClientProvider>
      </WagmiProvider>,
    )
  })
  return { chain, container, config, root, queryClient }
}

const text = () => h.container.textContent ?? ''
const buttons = () => Array.from(h.container.querySelectorAll('section[aria-label="Create a campaign"] button.btn')) as HTMLButtonElement[]
const mainAction = () => buttons().map((b) => b.textContent?.trim() ?? '').filter((t) => /Allow|Create campaign|Checking|Retry|Check allowance/.test(t))

async function typeInto(placeholder: string, value: string) {
  const input = h.container.querySelector(`input[placeholder="${placeholder}"]`) as HTMLInputElement
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(input, value)
    input.dispatchEvent(new Event('input', { bubbles: true }))
  })
}

/** Fill a valid campaign form with the given budget, the way a seller would. */
async function typeBudget(value: string) {
  await typeInto('Noise-cancelling headphones', 'Test headphones')
  await typeInto('https://yourstore.com/headphones', 'https://example.com/headphones')
  await typeInto('25.00', '0.05')
  await typeInto('100.00', value)
}

async function click(label: RegExp) {
  const button = buttons().find((b) => label.test(b.textContent ?? ''))
  if (!button) throw new Error(`no button matching ${label}; have ${JSON.stringify(mainAction())}`)
  await act(async () => {
    button.click()
  })
}

async function until(check: () => boolean, what: string, timeoutMs = 4000) {
  const start = Date.now()
  while (Date.now() - start < timeoutMs) {
    if (check()) return
    await act(async () => {
      await sleep(25)
    })
  }
  throw new Error(`timed out waiting for: ${what}. Buttons: ${JSON.stringify(mainAction())}. Tx area: ${(h.container.querySelector("[role=alert]")?.textContent ?? "") + (text().match(/Waiting for confirmation|Confirm in your wallet/)?.[0] ?? "")}`)
}

const showing = (re: RegExp) => () => mainAction().some((t) => re.test(t))

afterEach(async () => {
  await act(async () => {
    h?.root.unmount()
  })
  h?.queryClient.clear()
  document.body.innerHTML = ''
})

describe('Advertise approval step (Arc mainnet, 6 decimals)', () => {
  let chain: FakeChain
  beforeEach(() => {
    chain = new FakeChain()
    TX_TIMING.receiptTimeoutMs = 400
  })

  test('allowance 10000 and budget 0.01 go straight to Create campaign', async () => {
    chain.setAllowance(OWNER, ONE_CENT)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Create campaign/), 'Create campaign')
    expect(mainAction().join('|')).not.toMatch(/Allow/)
    expect(chain.sentTransactions).toHaveLength(0)
  })

  test('a fresh mount (page refresh) with the same allowance still skips approval', async () => {
    chain.setAllowance(OWNER, ONE_CENT)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Create campaign/), 'Create campaign')
    await act(async () => {
      h.root.unmount()
    })
    h.queryClient.clear()
    document.body.innerHTML = ''
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Create campaign/), 'Create campaign after refresh')
    expect(mainAction().join('|')).not.toMatch(/Allow/)
  })

  test('zero allowance requires approval for the exact budget', async () => {
    chain.setAllowance(OWNER, 0n)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow 0\.01 USDC/), 'Allow 0.01 USDC')
  })

  test('insufficient allowance requires approval', async () => {
    chain.setAllowance(OWNER, ONE_CENT - 1n)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
  })

  test('a failing allowance read shows an explicit error and retry, never a paid approval', async () => {
    chain.setAllowance(OWNER, 'fail')
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Retry allowance check/), 'Retry allowance check', 8000)
    expect(mainAction().join('|')).not.toMatch(/Allow 0|Create campaign/)
    expect(text()).toContain('could not read your USDC allowance')
    // The read recovers: retry advances to Create campaign without any approval.
    chain.setAllowance(OWNER, ONE_CENT)
    await click(/Retry allowance check/)
    await until(showing(/Create campaign/), 'Create campaign after retry')
    expect(chain.sentTransactions).toHaveLength(0)
  })

  test('while the read is loading no approval is offered', async () => {
    chain.setAllowance(OWNER, 'hang')
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Checking your USDC allowance/), 'loading state')
    expect(mainAction().join('|')).not.toMatch(/Allow 0|Create campaign/)
    expect(buttons().find((b) => /Checking/.test(b.textContent ?? ''))?.disabled).toBe(true)
  })

  test('account switching re-reads for the new owner and never reuses the old one', async () => {
    chain.setAllowance(OWNER, ONE_CENT)
    chain.setAllowance(OTHER, 0n)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Create campaign/), 'owner is ready')

    await disconnect(h.config)
    chain.account = OTHER
    await act(async () => {
      await connect(h.config, { connector: h.config.connectors[0], chainId: arc.id })
    })
    await until(showing(/Step 1 of 2: Allow/), 'other account needs approval')

    await act(async () => {
      await disconnect(h.config)
    })
    chain.account = OWNER
    await act(async () => {
      await connect(h.config, { connector: h.config.connectors[0], chainId: arc.id })
    })
    await until(showing(/Create campaign/), 'owner is ready again')
    expect(chain.sentTransactions).toHaveLength(0)
  })

  test('approval receipt advances to Create campaign even if the node still reports a stale allowance', async () => {
    chain.setAllowance(OWNER, 0n)
    chain.approvalUpdatesNode = false
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
    await click(/Step 1 of 2: Allow/)
    await until(showing(/Create campaign/), 'Create campaign after receipt', 8000)
    expect(chain.sentTransactions).toHaveLength(1)
    expect(chain.sentTransactions[0].data.startsWith('0x095ea7b3')).toBe(true) // approve(address,uint256)
    expect(mainAction().join('|')).not.toMatch(/Allow 0/)
  })

  test('a receipt for one account does not advance another account', async () => {
    chain.setAllowance(OWNER, 0n)
    chain.setAllowance(OTHER, 0n)
    chain.approvalUpdatesNode = false
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
    await click(/Step 1 of 2: Allow/)
    await until(showing(/Create campaign/), 'owner advanced', 8000)

    await act(async () => {
      await disconnect(h.config)
    })
    chain.account = OTHER
    await act(async () => {
      await connect(h.config, { connector: h.config.connectors[0], chainId: arc.id })
    })
    await until(showing(/Step 1 of 2: Allow/), 'other account still needs its own approval')
  })

  test('a receipt lookup failure is visible, blocks a second paid approval, and recovers from the chain', async () => {
    chain.setAllowance(OWNER, 0n)
    chain.receipt = 'error'
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
    await click(/Step 1 of 2: Allow/)
    await until(() => text().includes('could not confirm it yet'), 'visible receipt failure', 8000)
    expect(text()).toContain('Open transaction')
    expect(mainAction().join('|')).not.toMatch(/Allow 0/)
    expect(chain.sentTransactions).toHaveLength(1)

    // The approval lands; the allowance poll finds it and the flow advances without a second approval.
    chain.setAllowance(OWNER, ONE_CENT)
    await click(/Check allowance again/)
    await until(showing(/Create campaign/), 'Create campaign after chain shows the allowance')
    expect(chain.sentTransactions).toHaveLength(1)
  })

  test('a read that fails right before sending aborts the approval', async () => {
    chain.setAllowance(OWNER, 0n)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
    chain.setAllowance(OWNER, 'fail')
    await click(/Step 1 of 2: Allow/)
    await until(showing(/Retry allowance check/), 'retry state', 8000)
    expect(chain.sentTransactions).toHaveLength(0)
  })

  test('an allowance that appeared since the page last looked is never re-approved', async () => {
    chain.setAllowance(OWNER, 0n)
    h = await mount(chain)
    await typeBudget('0.01')
    await until(showing(/Step 1 of 2: Allow/), 'Allow')
    chain.setAllowance(OWNER, ONE_CENT) // e.g. an earlier approval confirmed in another tab
    await click(/Step 1 of 2: Allow/)
    await until(showing(/Create campaign/), 'Create campaign')
    expect(chain.sentTransactions).toHaveLength(0)
  })
})
