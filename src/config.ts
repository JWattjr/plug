/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 *
 * The active network comes from src/plug.config.ts, so switching networks is an env change.
 */

import { createConfig } from 'wagmi'
import { injected } from 'wagmi/connectors'
import { arc, arcTestnet } from 'viem/chains'
import { requireChain } from '@/onchain-facts'
import { rpcTransport } from '@/lib/rpc'
import { PLUG } from '@/plug.config'
import { registerChain } from './tracing'

const rpcFor = (chainId: number): readonly string[] => (PLUG.chainId === chainId ? PLUG.rpcUrls : [requireChain(chainId).rpcUrls[0]])

// Pre-register chain RPC URLs so trace events show correct chain names immediately
for (const url of PLUG.rpcUrls) registerChain(PLUG.chainId, url)

export const config = createConfig({
  // Both Arc networks are known to wagmi. The app only ever uses PLUG.chainId.
  chains: [arcTestnet, arc],
  connectors: [injected()],
  transports: {
    [arcTestnet.id]: rpcTransport(rpcFor(arcTestnet.id)),
    [arc.id]: rpcTransport(rpcFor(arc.id)),
  },
})
