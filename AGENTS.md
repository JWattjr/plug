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
- PlugCampaigns (Arc Testnet, chain 5042002): 0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa (current)
  - Superseded (old merchant model, do not use): 0xba5e6659f3ce5a327e831497d4aed96a1488f699
  - USDC constructor arg: 0x3600000000000000000000000000000000000000 (6 decimals ERC-20 view)
  - Model: advertiser IS the merchant. createCampaign(title, offerUrl, price, commissionBps, budget, endTime). Zero-based ids.
  - Source: contracts/PlugCampaigns.sol, tests: contracts/test/PlugCampaigns*.t.sol (89 tests)
  - buy never reverts on an undeliverable referrer: commission becomes 0 and accounting is restored.
  - Known tradeoffs: USDC issuer freeze of the contract address would lock pooled escrow; no pause by design.

## Web app (Plug)
- Config: src/plug.config.ts (chain, contract address, deploy block, demo agent), overridable by VITE_PLUG_* / VITE_DEMO_AGENT_ADDRESS env vars. Mainnet = env vars only.
- Pages: / , /advertise , /offers , /agent , /checkout/:id?ref=0x.. , /earnings/:address (src/pages). SPA fallbacks: vercel.json, public/_redirects.
- Demo agent address 0xDcF8ac99C8E427049764507eBe3aB1631e7E11cC (testnet only). Its private key is stored in .env as DEMO_AGENT_PRIVATE_KEY (not read by the app, never commit .env).
- ABI is generated from the compiled artifact into src/lib/plugAbi.ts. Regenerate it if the contract changes.
- UI was verified end to end against a fork of Arc Testnet (headless browser with a scripted wallet), because faucet funding was unavailable for the test wallets.
