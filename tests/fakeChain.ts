import {
  decodeFunctionData,
  encodeAbiParameters,
  encodeFunctionResult,
  erc20Abi,
  multicall3Abi,
  numberToHex,
  type Hex,
} from 'viem'
import { OWNER, SPENDER, USDC, ONE_CENT, approvalLog } from './fixtures'

export type Scenario = bigint | 'fail' | 'hang'

const MULTICALL3 = '0xca11bde05977b3631167028862be2a173976ca11'
const ALLOWANCE = '0xdd62ed3e'
const BALANCE_OF = '0x70a08231'
const CAMPAIGN_COUNT_PREFIX = '0x' // anything else on the Plug contract reverts, which is fine for these tests

const word = (n: bigint): Hex => encodeAbiParameters([{ type: 'uint256' }], [n])
const hash = (n: number): Hex => `0x${n.toString(16).padStart(64, '0')}`

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

  /** Public RPC refuses the batched (Multicall3) call, like a rate-limited endpoint. */
  failMulticall = false
  /** The wallet answers eth_call (its own node). Off by default so the public RPC is the only source. */
  walletReads = false
  /** What the wallet reports for eth_chainId after it has connected. */
  walletChainId = 5042
  private walletConnected = false

  account: `0x${string}` = OWNER
  allowanceCalls = 0
  sentTransactions: { from: string; to: string; data: string }[] = []
  private nextHash = 1

  setAllowance(owner: string, value: Scenario) {
    this.allowances.set(owner.toLowerCase(), value)
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
    if (to.toLowerCase() === SPENDER && data.length >= 10) return { ok: true, data: word(0n) } // campaignCount() = 0
    return { ok: false, data: CAMPAIGN_COUNT_PREFIX }
  }

  /** The public RPC. Pass to wagmi's `custom` transport. */
  rpc = async ({ method, params }: { method: string; params?: unknown }): Promise<unknown> => {
    const p = (params ?? []) as unknown[]
    switch (method) {
      case 'eth_chainId':
        return '0x13b2'
      case 'eth_blockNumber':
        return numberToHex(28_500_000n)
      case 'eth_getLogs':
        return []
      case 'eth_call': {
        const tx = p[0] as { to: string; data: Hex }
        if (tx.to.toLowerCase() === MULTICALL3) {
          if (this.failMulticall) throw new Error('HTTP request failed. Status: 429. Details: rate limit exceeded')
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
          if (result.data === '0x' && tx.data.startsWith(ALLOWANCE)) throw new Error('HTTP request failed. Status: 429')
          throw new Error('execution reverted')
        }
        return result.data
      }
      case 'eth_getTransactionReceipt': {
        if (this.receipt === 'error') throw new Error('HTTP request failed. Status: 503')
        if (this.receipt === 'pending') return null
        const txHash = p[0] as Hex
        if (this.approvalUpdatesNode) this.setAllowance(this.account, this.receiptAmount)
        const log = approvalLog(this.account, SPENDER, this.receiptAmount)
        return {
          blockHash: hash(99),
          blockNumber: numberToHex(28_500_001n),
          contractAddress: null,
          cumulativeGasUsed: '0x5208',
          effectiveGasPrice: '0x1',
          from: this.account,
          gasUsed: '0x5208',
          logs: [{ ...log, blockNumber: numberToHex(28_500_001n), transactionIndex: '0x0', logIndex: '0x0', blockHash: hash(99), transactionHash: txHash }],
          logsBloom: `0x${'00'.repeat(256)}`,
          status: '0x1',
          to: USDC,
          transactionHash: txHash,
          transactionIndex: '0x0',
          type: '0x2',
        }
      }
      default:
        throw new Error(`FakeChain: unsupported ${method}`)
    }
  }

  /** The injected wallet (MetaMask stand-in). eth_sendTransaction is recorded, never broadcast. */
  wallet = {
    request: async ({ method, params }: { method: string; params?: unknown }): Promise<unknown> => {
      const p = (params ?? []) as unknown[]
      switch (method) {
        case 'eth_requestAccounts':
        case 'eth_accounts':
          this.walletConnected = true
          return [this.account]
        case 'eth_chainId':
          // Connect with the right chain; afterwards the wallet may drift without telling the page.
          return this.walletConnected ? numberToHex(BigInt(this.walletChainId)) : '0x13b2'
        case 'eth_call': {
          if (!this.walletReads) throw new Error('FakeWallet: unsupported eth_call')
          const tx = p[0] as { to: string; data: Hex }
          const result = await this.call(tx.to, tx.data)
          if (!result.ok) throw new Error('execution reverted')
          return result.data
        }
        case 'wallet_switchEthereumChain':
          return null
        case 'eth_sendTransaction': {
          const tx = p[0] as { from: string; to: string; data: string }
          this.sentTransactions.push(tx)
          return hash(this.nextHash++)
        }
        default:
          throw new Error(`FakeWallet: unsupported ${method}`)
      }
    },
    on: () => undefined,
    removeListener: () => undefined,
  }
}
