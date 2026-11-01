import { encodeAbiParameters, encodeEventTopics, erc20Abi, type Hex } from 'viem'

export const OWNER = '0xCD64E3B41D523587718dA0D5689C9a48A489e289' as const
export const OTHER = '0x535df2938c7596497600564b41d0e98a5ea6b13b' as const
export const SPENDER = '0xaa5364de35d65633ad031ff4da4f941e0de6f913' as const
export const USDC = '0x3600000000000000000000000000000000000000' as const
export const ARC_MAINNET = 5042
export const ONE_CENT = 10_000n // 0.01 USDC, 6 decimals

/** A receipt log for approve(spender, value), shaped like the real ones. */
export function approvalLog(owner: string, spender: string, value: bigint, address: string = USDC) {
  const topics = encodeEventTopics({ abi: erc20Abi, eventName: 'Approval', args: { owner: owner as `0x${string}`, spender: spender as `0x${string}` } })
  const data: Hex = encodeAbiParameters([{ type: 'uint256' }], [value])
  return {
    address: address as `0x${string}`,
    topics: topics as [Hex, ...Hex[]],
    data,
    blockNumber: 1n,
    transactionHash: '0x038200e97071447a493620a976e0e0a94a6f7078f7291c1c9a269f69db486786' as Hex,
    transactionIndex: 0,
    blockHash: '0x00' as Hex,
    logIndex: 0,
    removed: false,
  }
}
