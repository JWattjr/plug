/**
 * Plug network configuration. One module, overridable by Vite env vars.
 *
 *   VITE_PLUG_CHAIN             "arc-testnet" (default) or "arc-mainnet"
 *   VITE_PLUG_ADDRESS           PlugCampaigns v2 contract address
 *   VITE_PLUG_DEPLOY_BLOCK      block the contract was deployed at (event scans start here)
 *   VITE_DEMO_AGENT_ADDRESS     payout address of the demo shopping agent
 *   VITE_PLUG_RPC_URL           optional RPC override (defaults to the public Arc RPC)
 *
 * Moving to mainnet needs env vars only: set VITE_PLUG_CHAIN=arc-mainnet and the
 * mainnet address and deploy block. No code change.
 */

import { arc, arcTestnet } from 'viem/chains'
import { getUsdc, requireChain } from '@/onchain-facts'
import { usdcDecimalsFor } from '@/onchain-money'

export type PlugNetwork = 'arc-testnet' | 'arc-mainnet'

interface NetworkDefaults {
  /** Contract address for this network, if one is deployed. */
  address?: `0x${string}`
  deployBlock?: bigint
  demoAgent?: `0x${string}`
}

/** Defaults baked in for each network. Mainnet has none until you deploy there. */
const DEFAULTS: Record<PlugNetwork, NetworkDefaults> = {
  'arc-testnet': {
    address: '0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9',
    deployBlock: 69644775n,
    demoAgent: '0xDcF8ac99C8E427049764507eBe3aB1631e7E11cC',
  },
  'arc-mainnet': {},
}

const CHAINS = {
  'arc-testnet': arcTestnet,
  'arc-mainnet': arc,
} as const

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/

function env(key: string): string | undefined {
  const value = (import.meta.env as Record<string, string | undefined>)[key]
  const trimmed = value?.trim()
  return trimmed ? trimmed : undefined
}

function readNetwork(): PlugNetwork {
  const raw = env('VITE_PLUG_CHAIN')?.toLowerCase()
  if (raw === 'arc-mainnet' || raw === 'arc' || raw === 'mainnet' || raw === '5042') return 'arc-mainnet'
  return 'arc-testnet'
}

function readAddress(key: string, fallback?: `0x${string}`): `0x${string}` | undefined {
  const raw = env(key)
  if (raw && ADDRESS_RE.test(raw)) return raw as `0x${string}`
  return fallback
}

function readBlock(fallback?: bigint): bigint | undefined {
  const raw = env('VITE_PLUG_DEPLOY_BLOCK')
  if (raw && /^\d+$/.test(raw)) return BigInt(raw)
  return fallback
}

const network = readNetwork()
const defaults = DEFAULTS[network]
const chain = CHAINS[network]
const chainFacts = requireChain(chain.id)
const usdc = getUsdc(chain.id)

export const PLUG = {
  network,
  chain,
  chainId: chain.id,
  chainName: chainFacts.name,
  isTestnet: chainFacts.isTestnet,
  /** Undefined until a contract is configured for this network. */
  address: readAddress('VITE_PLUG_ADDRESS', defaults.address),
  /** Event scans start here, never at block 0. */
  deployBlock: readBlock(defaults.deployBlock),
  /** Payout address of the demo shopping agent. */
  demoAgent: readAddress('VITE_DEMO_AGENT_ADDRESS', defaults.demoAgent),
  rpcUrl: env('VITE_PLUG_RPC_URL') ?? chainFacts.rpcUrls[0],
  explorerBase: chainFacts.explorerBase,
  usdcAddress: usdc?.address as `0x${string}` | undefined,
  usdcDecimals: usdcDecimalsFor(chain.id),
} as const

/** True when the app has everything it needs to talk to a deployed contract. */
export const PLUG_CONFIGURED = Boolean(PLUG.address && PLUG.usdcAddress && PLUG.deployBlock !== undefined)

export const ADDRESS_PATTERN = ADDRESS_RE
