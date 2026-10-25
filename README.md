# Plug

Ads for AI agents. Pay only when they sell. Sellers lock a USDC budget in a campaign, AI agents recommend the offer, and when a buyer purchases through an agent's link the sale splits on-chain: the seller gets the price and the agent gets its commission, in one transaction. Every offer is sponsored, and agents must say so.

Built with [Arc Studio](https://studio.arc.io)

## What you can do

- Create a campaign (title, link, price, commission, budget, duration), top it up, and end it to get unspent budget back.
- Browse live sponsored offers, with a panel and machine-readable JSON for agents.
- Chat with a demo shopping agent that matches your words to live offers and always discloses the sponsorship.
- Check out an offer, see the seller and agent split, and follow the transaction on the Arc explorer.
- Look up the commission any agent address has earned and the sales behind it.

## Tech stack

React, TypeScript, Vite, Tailwind CSS, wagmi and viem (injected browser wallet such as MetaMask or Rabby), React Router, Framer Motion. Contracts use Solidity and Foundry with OpenZeppelin.

## Development

Prerequisites: [Bun](https://bun.sh), and [Foundry](https://getfoundry.sh) if you want to build or test the contract.

```bash
bun install
bun run dev        # start the app on http://localhost:5173
bun run check      # lint and typecheck
bunx vite build  # production build
bun run contracts:build
bun run contracts:test
```

### Environment variables

All optional. Defaults point at the Arc Testnet deployment. Set them in `.env` (see `.env.example`).

- `VITE_PLUG_CHAIN`: `arc-testnet` (default) or `arc-mainnet`.
- `VITE_PLUG_ADDRESS`: address of the deployed PlugCampaigns contract.
- `VITE_PLUG_DEPLOY_BLOCK`: block the contract was deployed at. Event history is read from here.
- `VITE_DEMO_AGENT_ADDRESS`: payout address of the demo shopping agent.
- `VITE_PLUG_RPC_URL`: use your own RPC endpoint instead of the public Arc one.

Moving to mainnet needs only these variables, no code change: set the chain to `arc-mainnet` and give the mainnet contract address, deploy block and demo agent address.

### Hosting

Deep links such as `/checkout/3` need the host to serve `index.html` for unknown paths. `vercel.json` (Vercel) and `public/_redirects` (Netlify) already do this.

### Contract

The contract lives in `contracts/PlugCampaigns.sol` with its tests in `contracts/test/`. Arc Testnet deployment: `0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa`.


## Pay-per-sale economics

Plug is pay-per-sale advertising for AI agents on Arc. A seller locks a USDC advertising budget in a campaign. When an agent referral leads to a real on-chain purchase, the buyer pays the full purchase price to the seller and the contract pays the agent's commission from the seller's campaign budget, atomically in the same transaction. The commission does not reduce the seller's sale proceeds.

For example, on a 10 USDC purchase with a 20% commission, the seller receives the full 10 USDC and the agent receives 2 USDC from the seller's advertising budget.

### Why fraud does not pay

Plug pays for completed on-chain purchases, with no payment for impressions or clicks, so click fraud cannot earn a payout. A seller buying from itself only moves its own money. A third party faking a sale must pay the full purchase price and can recover at most 50% as commission, making the fake sale a net loss.

### Sponsored disclosure

Every offer is labelled **Sponsored**. Agents must disclose that an offer is sponsored when recommending it.

## Built with Arc Studio

[Arc Studio project](https://studio.arc.io/app/49ce882a-a246-44f3-a76d-ce91a33aa51a)

The contracts were written, tested (**89/89 Foundry tests, including invariants**), and audited with the **max preset** in Arc Studio. The app was also built in Arc Studio. The test and audit results describe the Arc Studio build; they were not rerun as part of this hosting setup.

Application and contract changes are made through Arc Studio. Later Arc Studio exports can be committed and pushed as received.

## Deployment links

- Live app: https://plug-tawny.vercel.app
- Public repository: https://github.com/JWattjr/plug
- Arc Testnet contract: `0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa` (chain ID 5042002)
- Arc Testnet contract explorer: https://explorer.testnet.arc.io/address/0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa
- Arc mainnet contract: TODO

The live app uses Arc Testnet defaults with no environment variables configured. Mainnet deployment details remain TODO.

### Build and test

```bash
npm install --legacy-peer-deps
npx vite build
forge test
```

The production output is `dist/`. The legacy peer dependency flag accommodates the Vite 6 project and the Vite <=5 peer declaration in `vite-plugin-node-polyfills`. Vercel uses the Vite framework preset, `bun install` (with `npm install --legacy-peer-deps` as the fallback), `npx vite build`, and `dist`. SPA rewrites in `vercel.json` support direct visits to routes such as `/offers` and `/checkout/0`.

## Next steps

Pay-per-impression via Circle Gateway Nanopayments, unlocked only for agents with a proven on-chain sales record. Sub-cent payments per view, with fraud capped by each agent's real conversion rate.
