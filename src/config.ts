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
import { resilientTransport } from '@/lib/readTransport'
import { rpcTransport } from '@/lib/rpc'
import { bindWalletReads } from '@/lib/walletReads'
import { PLUG } from '@/plug.config'
import { registerChain } from './tracing'

const rpcFor = (chainId: number): readonly string[] => (PLUG.chainId === chainId ? PLUG.rpcUrls : [requireChain(chainId).rpcUrls[0]])

/** The Plug chain reads over the public endpoints, then the connected wallet's read-only connection. */
const transportFor = (chainId: number) => {
  const urls = rpcFor(chainId)
  return PLUG.chainId === chainId ? resilientTransport({ chainId, urls, http: rpcTransport(urls) }) : rpcTransport(urls)
}

// Pre-register chain RPC URLs so trace events show correct chain names immediately
for (const url of PLUG.rpcUrls) registerChain(PLUG.chainId, url)

export const config = createConfig({
  // Both Arc networks are known to wagmi. The app only ever uses PLUG.chainId.
  chains: [arcTestnet, arc],
  connectors: [injected()],
  transports: {
    [arcTestnet.id]: transportFor(arcTestnet.id),
    [arc.id]: transportFor(arc.id),
  },
})

bindWalletReads(config)
