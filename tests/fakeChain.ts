import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  erc20Abi,
  multicall3Abi,
  numberToHex,
  type Hex,
} from 'viem'
import { plugAbi } from '../src/lib/plugAbi'
import { OWNER, SPENDER, USDC, ONE_CENT, approvalLog } from './fixtures'

export type Scenario = bigint | 'fail' | 'hang'

export interface FakeCampaign {
  advertiser: `0x${string}`
  title: string
  offerUrl: string
  price: bigint
  commissionBps: number
  budgetRemaining: bigint
  endTime: bigint
  active: boolean
  sales: bigint
  commissionPaid: bigint
  protectionWindow: bigint
  arbiter: `0x${string}`
  pendingOrders: bigint
  refundedCount: bigint
}

const MULTICALL3 = '0xca11bde05977b3631167028862be2a173976ca11'
const ALLOWANCE = '0xdd62ed3e'
const BALANCE_OF = '0x70a08231'
const APPROVE = '0x095ea7b3'
const ZERO = '0x0000000000000000000000000000000000000000' as const

/** The only wallet methods a read may use. Anything else reaching the wallet after connect is a test failure. */
const WALLET_READS = new Set([
  'eth_call',
  'eth_getTransactionReceipt',
  'eth_getTransactionByHash',
  'eth_blockNumber',
  'eth_getBlockByNumber',
  'eth_getLogs',
  'eth_getBalance',
  'eth_getCode',
])

const word = (n: bigint): Hex => encodeAbiParameters([{ type: 'uint256' }], [n])
const hash = (n: number): Hex => `0x${n.toString(16).padStart(64, '0')}`
const fail = (status: number, detail: string) => new Error(`HTTP request failed. Status: ${status}. Details: ${detail}`)

/** An in-memory Arc mainnet node plus injected wallet. Nothing here touches a network or signs anything. */
export class FakeChain {
  /** allowance(owner, Plug) as the node reports it, per lowercase owner. */
  allowances = new Map<string, Scenario>()
  defaultAllowance: Scenario = 0n
  receipt: 'ok' | 'error' | 'pending' = 'ok'
  /** What a mined approval receipt proves. */
  receiptAmount = ONE_CENT
  /** When true, a mined approval also raises the node's reported allowance. */
  approvalUpdatesNode = true

  /** Campaigns the contract holds. A mined createCampaign appends one. */
  campaigns: FakeCampaign[] = []
  /** Every public RPC request fails like a rate-limited or unreachable endpoint. */
  httpDown = false
  /** Public RPC never answers (a dead route that only times out). */
  httpHang = false
  /** Public RPC refuses the batched (Multicall3) call, like a rate-limited endpoint. */
  failMulticall = false
  /** The wallet answers allow-listed read methods from its own node. Off by default so the public RPC is the only source. */
  walletReads = false
  /** What the wallet reports for eth_chainId after it has connected. */
  walletChainId = 5042
  private walletConnected = false

  account: `0x${string}` = OWNER
  allowanceCalls = 0
  sentTransactions: { from: string; to: string; data: string; hash: Hex }[] = []
  /** Every method that reached the wallet, in order. */
  walletLog: string[] = []
  /** Public RPC requests by method. */
  publicLog: string[] = []
  private mined = new Set<Hex>()
  private nextHash = 1

  setAllowance(owner: string, value: Scenario) {
    this.allowances.set(owner.toLowerCase(), value)
  }

  /** The campaign from the production incident: 0.01 USDC price, 0.01 USDC budget, 20% commission, 7 days. */
  addCampaign(over: Partial<FakeCampaign> = {}): FakeCampaign {
    const campaign: FakeCampaign = {
      advertiser: OWNER,
      title: 'NCH',
      offerUrl: 'http://yourstore.com/headphones',
      price: 10_000n,
      commissionBps: 2000,
      budgetRemaining: 10_000n,
      endTime: BigInt(Math.floor(Date.now() / 1000) + 7 * 86_400),
      active: true,
      sales: 0n,
      commissionPaid: 0n,
      protectionWindow: 0n,
      arbiter: ZERO,
      pendingOrders: 0n,
      refundedCount: 0n,
      ...over,
    }
    this.campaigns.push(campaign)
    return campaign
  }

  private allowanceFor(owner: string): Scenario {
    return this.allowances.get(owner.toLowerCase()) ?? this.defaultAllowance
  }

  private async call(to: string, data: Hex): Promise<{ ok: boolean; data: Hex }> {
    const selector = data.slice(0, 10)
    if (to.toLowerCase() === USDC && selector === ALLOWANCE) {
      this.allowanceCalls += 1
      const { args } = decodeFunctionData({ abi: erc20Abi, data })
      const value = this.allowanceFor(args![0] as string)
      if (value === 'hang') return new Promise(() => undefined)
      if (value === 'fail') return { ok: false, data: '0x' }
      return { ok: true, data: word(value) }
    }
    if (to.toLowerCase() === USDC && selector === BALANCE_OF) return { ok: true, data: word(5_683_603n) }
    if (to.toLowerCase() === SPENDER) {
      try {
        const decoded = decodeFunctionData({ abi: plugAbi, data })
        if (decoded.functionName === 'campaignCount') return { ok: true, data: word(BigInt(this.campaigns.length)) }
        if (decoded.functionName === 'orderCount') return { ok: true, data: word(0n) }
        if (decoded.functionName === 'getCampaign') {
          const campaign = this.campaigns[Number((decoded.args as readonly [bigint])[0])]
          if (!campaign) return { ok: false, data: '0x' }
          return { ok: true, data: encodeFunctionResult({ abi: plugAbi, functionName: 'getCampaign', result: campaign }) }
        }
      } catch {
        // not a Plug call this fake knows
      }
    }
    return { ok: false, data: '0x' }
  }

  /** What a mined transaction does to chain state and which logs it emits. Idempotent per hash. */
  private mine(txHash: Hex) {
    const tx = this.sentTransactions.find((t) => t.hash === txHash)
    if (!tx) return { logs: [], to: USDC as string }
    const first = !this.mined.has(txHash)
    this.mined.add(txHash)
    const from = tx.from as `0x${string}`
    if (tx.data.startsWith(APPROVE)) {
      if (first && this.approvalUpdatesNode) this.setAllowance(from, this.receiptAmount)
      return { logs: [approvalLog(from, SPENDER, this.receiptAmount)], to: USDC as string }
    }
    const decoded = decodeFunctionData({ abi: plugAbi, data: tx.data as Hex })
    if (decoded.functionName === 'createCampaign') {
      const [title, offerUrl, price, commissionBps, budget, endTime, protectionWindow, arbiter] = decoded.args as readonly [
        string, string, bigint, number, bigint, bigint, bigint, `0x${string}`,
      ]
      let id = this.campaigns.findIndex((c) => c.title === title && c.advertiser === from && c.endTime === endTime)
      if (first || id < 0) {
        id = this.campaigns.length
        this.addCampaign({ advertiser: from, title, offerUrl, price, commissionBps, budgetRemaining: budget, endTime, protectionWindow, arbiter })
        this.setAllowance(from, 0n) // the budget transfer consumed the allowance
      }
      const event = plugAbi.find((i) => i.type === 'event' && i.name === 'CampaignCreated')!
      const topics = encodeEventTopics({ abi: plugAbi, eventName: 'CampaignCreated', args: { id: BigInt(id), advertiser: from } })
      const data = encodeAbiParameters(
        event.inputs.filter((i) => !i.indexed),
        [price, commissionBps, budget, endTime, protectionWindow, arbiter],
      )
      const transfer = {
        address: USDC,
        topics: [
          '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef',
          encodeAbiParameters([{ type: 'address' }], [from]),
          encodeAbiParameters([{ type: 'address' }], [SPENDER]),
        ] as Hex[],
        data: word(budget),
      }
      return {
        logs: [
          { ...transfer, blockNumber: 1n, transactionHash: txHash, transactionIndex: 0, blockHash: hash(99), logIndex: 0, removed: false },
          { address: SPENDER, topics: topics as Hex[], data, blockNumber: 1n, transactionHash: txHash, transactionIndex: 0, blockHash: hash(99), logIndex: 1, removed: false },
        ],
        to: SPENDER as string,
      }
    }
    return { logs: [], to: SPENDER as string }
  }

  private async core(method: string, p: unknown[]): Promise<unknown> {
    switch (method) {
      case 'eth_chainId':
        return '0x13b2'
      case 'eth_blockNumber':
        return numberToHex(28_995_400n)
      case 'eth_getLogs':
        return []
      case 'eth_getBlockByNumber':
        return {
          number: numberToHex(28_995_400n),
          hash: hash(98),
          parentHash: hash(97),
          timestamp: numberToHex(BigInt(Math.floor(Date.now() / 1000))),
          transactions: [],
          gasLimit: '0x1',
          gasUsed: '0x0',
          miner: ZERO,
          nonce: '0x0000000000000000',
          size: '0x1',
          difficulty: '0x0',
          totalDifficulty: '0x0',
          extraData: '0x',
          logsBloom: `0x${'00'.repeat(256)}`,
          sha3Uncles: hash(0),
          stateRoot: hash(0),
          receiptsRoot: hash(0),
          transactionsRoot: hash(0),
          uncles: [],
        }
      case 'eth_getTransactionByHash':
        return null
      case 'eth_call': {
        const tx = p[0] as { to: string; data: Hex }
        if (tx.to.toLowerCase() === MULTICALL3) {
          if (this.failMulticall) throw fail(429, 'rate limit exceeded')
          const { args } = decodeFunctionData({ abi: multicall3Abi, data: tx.data })
          const calls = args![0] as readonly { target: string; callData: Hex }[]
          const results = await Promise.all(calls.map((c) => this.call(c.target, c.callData)))
          return encodeFunctionResult({
            abi: multicall3Abi,
            functionName: 'aggregate3',
            result: results.map((r) => ({ success: r.ok, returnData: r.data })),
          })
        }
        const result = await this.call(tx.to, tx.data)
        if (!result.ok) {
          if (result.data === '0x' && tx.data.startsWith(ALLOWANCE)) throw fail(429, 'rate limit exceeded')
          throw new Error('execution reverted')
        }
        return result.data
      }
      case 'eth_getTransactionReceipt': {
        if (this.receipt === 'error') throw fail(503, 'service unavailable')
        if (this.receipt === 'pending') return null
        const txHash = p[0] as Hex
        const sent = this.sentTransactions.find((t) => t.hash === txHash)
        if (!sent && this.sentTransactions.length > 0) return null
        const { logs, to } = this.mine(txHash)
        return {
          blockHash: hash(99),
          blockNumber: numberToHex(28_995_339n),
          contractAddress: null,
          cumulativeGasUsed: '0x5208',
          effectiveGasPrice: '0x1',
          from: sent?.from ?? this.account,
          gasUsed: '0x5208',
          logs: logs.map((log) => ({
            ...log,
            blockNumber: numberToHex(28_995_339n),
            transactionIndex: '0x0',
            logIndex: numberToHex(BigInt(log.logIndex)),
            blockHash: hash(99),
            transactionHash: txHash,
          })),
          logsBloom: `0x${'00'.repeat(256)}`,
          status: '0x1',
          to,
          transactionHash: txHash,
          transactionIndex: '0x0',
          type: '0x2',
        }
      }
      default:
        throw new Error(`FakeChain: unsupported ${method}`)
    }
  }

  /** The public RPC. Pass to wagmi's `custom` transport. */
  rpc = async ({ method, params }: { method: string; params?: unknown }): Promise<unknown> => {
    this.publicLog.push(method)
    if (this.httpHang) return new Promise(() => undefined)
    if (this.httpDown) throw fail(429, 'Request exceeds defined limit. rate limit exceeded')
    return this.core(method, (params ?? []) as unknown[])
  }

  /** The injected wallet (MetaMask stand-in). eth_sendTransaction is recorded, never broadcast. */
  wallet = {
    request: async ({ method, params }: { method: string; params?: unknown }): Promise<unknown> => {
      const p = (params ?? []) as unknown[]
      this.walletLog.push(method)
      switch (method) {
        case 'eth_requestAccounts':
        case 'eth_accounts':
          this.walletConnected = true
          return [this.account]
        case 'eth_chainId':
          // Connect with the right chain; afterwards the wallet may drift without telling the page.
          return this.walletConnected ? numberToHex(BigInt(this.walletChainId)) : '0x13b2'
        case 'wallet_switchEthereumChain':
          return null
        case 'eth_sendTransaction': {
          const tx = p[0] as { from: string; to: string; data: string }
          const txHash = hash(this.nextHash++)
          this.sentTransactions.push({ ...tx, hash: txHash })
          return txHash
        }
        default:
          if (WALLET_READS.has(method) && this.walletReads) return this.core(method, p)
          throw new Error(`FakeWallet: unsupported ${method}`)
      }
    },
    on: () => undefined,
    removeListener: () => undefined,
  }
}

// Used by tests that decode what a fake wallet was asked to send.
export { decodeAbiParameters }
