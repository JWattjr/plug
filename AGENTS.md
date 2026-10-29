# [App Name]

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

[Brief description of what the app does and its primary use case]

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Main application logic
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## To Run

```bash
bun install
bun run dev
```

## Deployed contracts
- PlugCampaigns v2 (Arc Testnet, chain 5042002): 0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9 (current, used by the app)
  - Deploy block: 69644775. USDC constructor arg: 0x3600000000000000000000000000000000000000 (6 decimals ERC-20 view).
  - Model: advertiser IS the seller. createCampaign(title, offerUrl, price, commissionBps, budget, endTime, protectionWindow, arbiter). Window 0 = instant settlement; window up to 30 days holds the price in escrow with dispute/contest/arbiter flows.
  - Accounting invariant: usdc.balanceOf(plug) == sum(budgetRemaining) + reservedCommission + escrowedPrice + owedRefunds.
  - Tests: contracts/test/PlugCampaigns*.t.sol (302 tests incl. invariants). Known tradeoffs: pooled escrow is exposed to a USDC issuer freeze of the contract; order-history getters are unpaginated arrays.
- Superseded, do not use: v1 0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa, 0xba5e6659f3ce5a327e831497d4aed96a1488f699.

## Web app (Plug)
- Config: src/plug.config.ts (chain, contract address, deploy block, demo agent), overridable by VITE_PLUG_* / VITE_DEMO_AGENT_ADDRESS env vars. Mainnet = env vars only.
- Pages: / , /advertise , /offers , /agent , /checkout/:id?ref=0x.. , /orders , /orders/:id , /arbiter , /activity , /earnings/:address (src/pages). SPA fallbacks: vercel.json, public/_redirects.
- Demo agent address 0xDcF8ac99C8E427049764507eBe3aB1631e7E11cC (testnet only). Its private key is stored in .env as DEMO_AGENT_PRIVATE_KEY (not read by the app, never commit .env).
- ABI is generated from the compiled artifact into src/lib/plugAbi.ts. Regenerate it if the contract changes.
- UI was verified end to end against a fork of Arc Testnet (headless browser with a scripted wallet), because faucet funding was unavailable for the test wallets.
- v2 UI was verified end to end on a local anvil chain with a mock USDC at the Arc USDC address and a Multicall3 copy (wagmi batches reads through it). Faucet funding is unavailable for the test wallets and transferFrom on forked Arc USDC needs the Arc-aware fork node.
- The app clock follows the latest block time (src/hooks/useChainClock.ts), so countdowns match the contract's block.timestamp.
