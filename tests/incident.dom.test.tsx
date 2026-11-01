import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { TX_TIMING } from '../src/hooks/useTx'
import { WALLET_READ_METHODS } from '../src/lib/walletReads'
import { FakeChain } from './fakeChain'
import { OWNER, ONE_CENT } from './fixtures'
import {
  buttonsOf, click, fillCampaignForm, mountApp, resetEnvironment, textOf, unmountApp, until, type Mounted,
} from './incidentHarness'

let chain: FakeChain
let m: Mounted | undefined

const CREATE_SELECTOR_LEN = 10
const hasButton = (label: RegExp) => () => m !== undefined && buttonsOf(m).some((b) => label.test(b))

beforeEach(() => {
  chain = new FakeChain()
  resetEnvironment(chain)
  TX_TIMING.receiptTimeoutMs = 400
  TX_TIMING.pollMs = 40
})

afterEach(async () => {
  if (m) await unmountApp(m)
  m = undefined
  document.body.innerHTML = ''
  localStorage.clear()
})

/** After connecting, the wallet may only ever be asked to read (allow-listed methods) or to send the user's own transaction. */
function assertWalletOnlyReadsOrSends(sends: number) {
  const afterConnect = chain.walletLog.filter((method) => method !== 'eth_chainId')
  const unexpected = afterConnect.filter((method) => !WALLET_READ_METHODS.has(method) && method !== 'eth_sendTransaction')
  if (unexpected.length) throw new Error(`unexpected wallet methods: ${unexpected.join(",")} | full log: ${chain.walletLog.join(",")}`)
  expect(afterConnect.filter((method) => method === 'eth_sendTransaction')).toHaveLength(sends)
  expect(chain.walletLog).not.toContain('wallet_requestPermissions')
  expect(chain.walletLog).not.toContain('wallet_switchEthereumChain')
  expect(chain.walletLog).not.toContain('personal_sign')
}

describe('production incident: public HTTP reads fail, the connected wallet works', () => {
  test('existing allowance 10000 + budget 10000 -> Create (sent once) -> confirmed via wallet -> campaign 0 is listed, with failed attempts inspectable', async () => {
    chain.httpDown = true
    chain.walletReads = true
    chain.setAllowance(OWNER, ONE_CENT)
    m = await mountApp(chain, '/advertise')
    await fillCampaignForm(m)
    await until(m, hasButton(/Create campaign/), 'Create campaign (allowance read through the wallet)')
    expect(buttonsOf(m).join('|')).not.toMatch(/Allow 0/)
    expect(chain.sentTransactions).toHaveLength(0)

    await click(m, /Create campaign/)
    await until(m, () => textOf(m!).includes('Campaign #0 is live'), 'campaign 0 confirmed')
    expect(chain.sentTransactions).toHaveLength(1)
    expect(chain.sentTransactions[0].data.startsWith('0x095ea7b3')).toBe(false) // a create, never an approval
    expect(chain.sentTransactions[0].data.slice(0, CREATE_SELECTOR_LEN)).not.toBe('0x')

    // The real campaign is listed under My campaigns, never "No campaigns yet".
    await until(m, () => textOf(m!).includes('NCH'), 'campaign listed in My campaigns')
    expect(textOf(m)).not.toContain('No campaigns yet')
    expect(textOf(m)).not.toContain('Could not read your campaigns')

    // The public route's failures stay inspectable even though the wallet answered.
    const notice = m.container.querySelector('[data-testid="read-route-notice"]')?.textContent ?? ''
    expect(notice).toContain('your wallet answered them instead')
    expect(notice).toContain('rate limit exceeded')
    expect(notice).toContain('Status: 429')
    expect(notice).toContain('via wallet')
    assertWalletOnlyReadsOrSends(1)
  })

  test('the existing campaign 0 appears in Offers and in checkout/0 over wallet reads', async () => {
    chain.httpDown = true
    chain.walletReads = true
    chain.addCampaign()
    m = await mountApp(chain, '/offers')
    await until(m, () => textOf(m!).includes('NCH'), 'NCH in Offers')
    expect(textOf(m)).not.toContain('No live offers yet')
    await unmountApp(m)

    m = await mountApp(chain, '/checkout/0')
    await until(m, () => textOf(m!).includes('Campaign #0') && textOf(m!).includes('NCH'), 'checkout/0 shows the campaign')
    expect(textOf(m)).not.toContain('does not exist')
    assertWalletOnlyReadsOrSends(0)
  })

  test('failed reads are errors with a retry, never "No campaigns yet" or "No live offers yet"', async () => {
    chain.httpDown = true // and the wallet cannot answer either
    chain.addCampaign()
    m = await mountApp(chain, '/advertise')
    await until(m, () => textOf(m!).includes('Could not read your campaigns'), 'campaigns read error')
    expect(textOf(m)).not.toContain('No campaigns yet')
    expect(m.container.querySelector('[data-testid="read-diagnostics"]')?.textContent ?? '').toContain('rate limit exceeded')

    // Recovers on retry without reloading.
    chain.httpDown = false
    await click(m, /^Retry$/)
    await until(m, () => textOf(m!).includes('NCH'), 'campaign appears after retry')
    await unmountApp(m)

    chain.httpDown = true
    m = await mountApp(chain, '/offers')
    await until(m, () => textOf(m!).includes('Could not read live offers'), 'offers read error')
    expect(textOf(m)).not.toContain('No live offers yet')
    await unmountApp(m)

    m = await mountApp(chain, '/checkout/0')
    await until(m, () => textOf(m!).includes('Could not read campaign #0'), 'checkout read error')
    expect(textOf(m)).not.toContain('does not exist')
  })

  test('a wallet on another chain is never trusted for any read', async () => {
    chain.httpDown = true
    chain.walletReads = true
    chain.setAllowance(OWNER, ONE_CENT)
    chain.addCampaign()
    // The wallet connected on Arc, then drifts to another chain without telling the page.
    m = await mountApp(chain, '/advertise', { afterConnect: () => { chain.walletChainId = 1 } })
    await fillCampaignForm(m)
    await until(m, () => textOf(m!).includes('Could not read your campaigns'), 'campaigns refused')
    await until(m, hasButton(/Retry allowance check/), 'allowance refused')
    expect(buttonsOf(m).join('|')).not.toMatch(/Create campaign|Allow 0/)
    expect(textOf(m)).not.toContain('NCH')
    expect(textOf(m)).toContain('Wallet is on chain 1, not 5042')
    // Not a single data read reached the wallet: only chain checks.
    expect(chain.walletLog.filter((method) => method !== 'eth_chainId')).toEqual([])
    expect(chain.walletLog).toContain('eth_chainId')
  })

  test('visitors without a wallet use the public endpoints and never touch a wallet', async () => {
    chain.addCampaign()
    m = await mountApp(chain, '/offers', { connected: false })
    await until(m, () => textOf(m!).includes('NCH'), 'offers over public HTTP')
    expect(chain.walletLog).toEqual([])
  })

  test('a public route that hangs is abandoned for the wallet within the bounded budget', async () => {
    chain.httpHang = true
    chain.walletReads = true
    chain.addCampaign()
    const started = Date.now()
    m = await mountApp(chain, '/offers')
    await until(m, () => textOf(m!).includes('NCH'), 'wallet answers while HTTP hangs', 5000)
    expect(Date.now() - started).toBeLessThan(5000)
  })
})

describe('a sent transaction that cannot be confirmed', () => {
  test('timeout -> reload -> status check recovers the existing campaign with no extra send', async () => {
    chain.walletReads = true
    chain.receipt = 'pending'
    chain.setAllowance(OWNER, ONE_CENT)
    m = await mountApp(chain, '/advertise')
    await fillCampaignForm(m)
    await until(m, hasButton(/Create campaign/), 'Create campaign')
    await click(m, /Create campaign/)
    await until(m, () => textOf(m!).includes('could not confirm it yet'), 'unresolved notice')
    expect(textOf(m)).toContain('Open transaction')
    expect(hasButton(/Check campaign transaction status/)()).toBe(true)
    expect(buttonsOf(m).join('|')).not.toMatch(/Step 2 of 2: Create campaign|Allow 0/)
    expect(chain.sentTransactions).toHaveLength(1)

    // Reload: the remembered hash is restored and still blocks a second create.
    await unmountApp(m)
    m = await mountApp(chain, '/advertise')
    await until(m, () => textOf(m!).includes('could not confirm it yet'), 'unresolved after reload')
    expect(buttonsOf(m).join('|')).not.toMatch(/Step 2 of 2: Create campaign|Allow 0/)
    expect(hasButton(/Check campaign transaction status/)()).toBe(true)

    // It was mined all along. A read-only status check finds it and shows the existing campaign.
    chain.receipt = 'ok'
    await click(m, /Check campaign transaction status/)
    await until(m, () => textOf(m!).includes('Campaign #0 is live'), 'existing campaign recovered')
    await until(m, () => textOf(m!).includes('NCH'), 'listed in My campaigns')
    expect(chain.sentTransactions).toHaveLength(1)
    expect(textOf(m)).not.toContain('could not confirm it yet')
    expect(localStorage.length).toBe(0) // nothing left to recover
    assertWalletOnlyReadsOrSends(0) // since the reload the wallet was only read from, never asked to send
  })

  test('a reload with the transaction already mined recovers on its own, without any click or send', async () => {
    chain.walletReads = true
    chain.receipt = 'pending'
    chain.setAllowance(OWNER, ONE_CENT)
    m = await mountApp(chain, '/advertise')
    await fillCampaignForm(m)
    await until(m, hasButton(/Create campaign/), 'Create campaign')
    await click(m, /Create campaign/)
    await until(m, () => textOf(m!).includes('could not confirm it yet'), 'unresolved notice')
    await unmountApp(m)

    chain.receipt = 'ok'
    m = await mountApp(chain, '/advertise')
    await until(m, () => textOf(m!).includes('Campaign #0 is live'), 'recovered automatically after reload')
    expect(chain.sentTransactions).toHaveLength(1)
  })

  test('a receipt lookup that errors is shown as unresolved, not as success or failure', async () => {
    chain.walletReads = true
    chain.receipt = 'error'
    chain.setAllowance(OWNER, ONE_CENT)
    m = await mountApp(chain, '/advertise')
    await fillCampaignForm(m)
    await until(m, hasButton(/Create campaign/), 'Create campaign')
    await click(m, /Create campaign/)
    await until(m, () => textOf(m!).includes('could not confirm it yet'), 'unresolved notice')
    expect(textOf(m)).toContain('Last read problem')
    expect(textOf(m)).not.toContain('is live')
    expect(chain.sentTransactions).toHaveLength(1)
  })

  test('a confirmed success survives a failing refresh', async () => {
    chain.setAllowance(OWNER, ONE_CENT)
    m = await mountApp(chain, '/advertise')
    m.queryClient.invalidateQueries = async () => {
      throw new Error('refresh failed')
    }
    await fillCampaignForm(m)
    await until(m, hasButton(/Create campaign/), 'Create campaign')
    await click(m, /Create campaign/)
    await until(m, () => textOf(m!).includes('Campaign #0 is live'), 'success despite refresh failure')
    expect(textOf(m)).not.toContain('could not confirm it yet')
    expect(chain.sentTransactions).toHaveLength(1)
  })
})
