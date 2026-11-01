import { describe, expect, test } from 'bun:test'
import { approvalKey, approvedAmountFromReceipt, resolveApprovalGate, type AllowanceRead } from '../src/lib/approval'
import { readUsdcAllowance, usdcAllowanceKey } from '../src/hooks/useUsdc'
import { PLUG } from '../src/plug.config'
import { ARC_MAINNET, ONE_CENT, OTHER, OWNER, SPENDER, USDC, approvalLog } from './fixtures'

const read = (over: Partial<AllowanceRead> = {}): AllowanceRead => ({ data: undefined, isPending: false, isError: false, isIdle: false, ...over })

describe('app is pinned to the live Arc mainnet deployment', () => {
  test('chain, spender, USDC and decimals', () => {
    expect(PLUG.chainId).toBe(ARC_MAINNET)
    expect(PLUG.address).toBe(SPENDER)
    expect(PLUG.usdcAddress?.toLowerCase()).toBe(USDC)
    expect(PLUG.usdcDecimals).toBe(6)
  })
})

describe('resolveApprovalGate', () => {
  test('allowance 10000 and budget 10000 goes straight to create', () => {
    const gate = resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ data: ONE_CENT }) })
    expect(gate.kind).toBe('ready')
  })

  test('allowance above the budget is ready', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ data: 5n * ONE_CENT }) }).kind).toBe('ready')
  })

  test('a successful zero read requires approval', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ data: 0n }) })).toEqual({ kind: 'required', have: 0n })
  })

  test('an insufficient read requires approval', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ data: ONE_CENT - 1n }) }).kind).toBe('required')
  })

  test('REGRESSION: a missing read is unknown, not zero', () => {
    // The old code did `(allowance.data ?? 0n) < budget`, which offered a paid approval here.
    expect((undefined ?? 0n) < ONE_CENT).toBe(true)
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ isPending: true }) }).kind).toBe('loading')
  })

  test('REGRESSION: a failed read never offers an approval', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ isError: true }) }).kind).toBe('error')
  })

  test('a stale value below the budget plus a failed refresh is an error, not an approval', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ data: 0n, isError: true }) }).kind).toBe('error')
  })

  test('a query that cannot run is an error, not loading forever or an approval', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: 0n, read: read({ isPending: true, isIdle: true }) }).kind).toBe('error')
  })

  test('zero budget needs no approval and no read', () => {
    expect(resolveApprovalGate({ budget: 0n, receiptAmount: 0n, read: read({ isError: true }) }).kind).toBe('none')
  })

  test('a verified approval receipt advances even while the read lags or fails', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: ONE_CENT, read: read({ data: 0n }) }).kind).toBe('ready')
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: ONE_CENT, read: read({ isError: true }) }).kind).toBe('ready')
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: ONE_CENT, read: read({ isPending: true }) }).kind).toBe('ready')
  })

  test('a receipt smaller than the budget does not advance', () => {
    expect(resolveApprovalGate({ budget: ONE_CENT, receiptAmount: ONE_CENT - 1n, read: read({ data: 0n }) }).kind).toBe('required')
  })
})

describe('approvedAmountFromReceipt', () => {
  const match = { token: USDC, owner: OWNER, spender: SPENDER }

  test('reads approve(Plug, 10000) from the real receipt shape', () => {
    expect(approvedAmountFromReceipt({ logs: [approvalLog(OWNER, SPENDER, ONE_CENT)] }, match)).toBe(ONE_CENT)
  })

  test('is case-insensitive on addresses', () => {
    const lower = { token: USDC, owner: OWNER.toLowerCase(), spender: SPENDER.toUpperCase().replace('0X', '0x') }
    expect(approvedAmountFromReceipt({ logs: [approvalLog(OWNER, SPENDER, ONE_CENT)] }, lower)).toBe(ONE_CENT)
  })

  test('ignores another owner, spender or token contract', () => {
    expect(approvedAmountFromReceipt({ logs: [approvalLog(OTHER, SPENDER, ONE_CENT)] }, match)).toBe(0n)
    expect(approvedAmountFromReceipt({ logs: [approvalLog(OWNER, OTHER, ONE_CENT)] }, match)).toBe(0n)
    expect(approvedAmountFromReceipt({ logs: [approvalLog(OWNER, SPENDER, ONE_CENT, OTHER)] }, match)).toBe(0n)
  })

  test('no Approval event means no proof', () => {
    expect(approvedAmountFromReceipt({ logs: [] }, match)).toBe(0n)
  })
})

describe('allowance query', () => {
  test('reads allowance(owner, Plug) on the USDC token', async () => {
    const calls: unknown[] = []
    const value = await readUsdcAllowance(
      { readContract: async (args) => (calls.push(args), ONE_CENT) },
      USDC,
      OWNER,
      SPENDER,
    )
    expect(value).toBe(ONE_CENT)
    expect(calls).toHaveLength(1)
    const call = calls[0] as { address: string; functionName: string; args: string[] }
    expect(call.address).toBe(USDC)
    expect(call.functionName).toBe('allowance')
    expect(call.args).toEqual([OWNER, SPENDER])
  })

  test('a rejected read rejects, so the query errors instead of yielding zero', async () => {
    await expect(readUsdcAllowance({ readContract: async () => { throw new Error('HTTP request failed') } }, USDC, OWNER, SPENDER)).rejects.toThrow('HTTP request failed')
  })

  test('a non-uint256 answer is rejected', async () => {
    await expect(readUsdcAllowance({ readContract: async () => undefined }, USDC, OWNER, SPENDER)).rejects.toThrow()
  })

  test('cache key is scoped to chain, token, owner and spender, case-insensitively', () => {
    const a = usdcAllowanceKey(OWNER, SPENDER)
    expect(usdcAllowanceKey(OWNER.toLowerCase(), SPENDER.toUpperCase().replace('0X', '0x'))).toEqual(a)
    expect(usdcAllowanceKey(OTHER, SPENDER)).not.toEqual(a)
    expect(a).toContain(ARC_MAINNET)
  })

  test('receipt proof is scoped per chain and account', () => {
    const k = approvalKey(ARC_MAINNET, USDC, OWNER, SPENDER)
    expect(approvalKey(ARC_MAINNET, USDC, OWNER.toLowerCase(), SPENDER)).toBe(k)
    expect(approvalKey(ARC_MAINNET, USDC, OTHER, SPENDER)).not.toBe(k)
    expect(approvalKey(5042002, USDC, OWNER, SPENDER)).not.toBe(k)
  })
})
