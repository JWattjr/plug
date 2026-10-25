import { useCallback } from 'react'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { PLUG } from '@/plug.config'

/** Connection and network state for the injected browser wallet (MetaMask, Rabby). */
export function useWalletGate() {
  const { address, chainId, isConnected, isConnecting, isReconnecting } = useAccount()
  const { connectAsync, connectors, isPending: connectPending, error: connectError } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChainAsync, isPending: switchPending, error: switchError } = useSwitchChain()

  const hasInjectedWallet = typeof window !== 'undefined' && Boolean((window as { ethereum?: unknown }).ethereum)
  const wrongNetwork = isConnected && chainId !== PLUG.chainId

  const connect = useCallback(() => {
    const connector = connectors[0]
    if (!connector) return
    // A rejected or closed prompt is exposed as connectError.
    connectAsync({ connector, chainId: PLUG.chainId }).catch(() => undefined)
  }, [connectAsync, connectors])

  const switchNetwork = useCallback(() => {
    // wagmi asks the wallet to add Arc if it does not know the chain yet.
    // A rejection is exposed as switchError.
    switchChainAsync({ chainId: PLUG.chainId }).catch(() => undefined)
  }, [switchChainAsync])

  return {
    address,
    chainId,
    isConnected,
    isConnecting: isConnecting || isReconnecting || connectPending,
    hasInjectedWallet,
    wrongNetwork,
    connect,
    disconnect,
    switchNetwork,
    switchPending,
    connectError,
    switchError,
  }
}
