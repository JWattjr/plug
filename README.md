# Plug

Ads for AI agents. Pay only when they sell. Sellers lock a USDC budget in a campaign and AI agents recommend the offer. Plug v2 adds buyer protection: protected purchases hold the buyer's price in escrow until the order settles, when the seller receives the full price and the agent receives its commission from the seller's advertising budget. Instant-settlement campaigns pay the seller and agent in the purchase transaction. Every offer is sponsored, and agents must say so.

Built with [Arc Studio](https://studio.arc.io)

## What you can do

- Create a campaign (title, link, price, commission, budget, duration, buyer protection window, and public arbiter), top it up, and end it to get unspent budget back.
- Browse live sponsored offers, with a panel and machine-readable JSON for agents.
- Chat with a demo shopping agent that matches your words to live offers and always discloses the sponsorship.
- Check out an offer, see the seller and agent split, and follow the transaction on the Arc explorer.
- Look up the commission any agent address has earned and the sales behind it.
- Manage protected orders on `/orders`, review contested orders on `/arbiter`, and browse on-chain events on `/activity`.

## Tech stack

React, TypeScript, Vite, Tailwind CSS, wagmi and viem (injected browser wallet such as MetaMask or Rabby), React Router, Framer Motion. Contracts use Solidity and Foundry with OpenZeppelin.

## Development

Prerequisites: [Bun](https://bun.sh), and [Foundry](https://getfoundry.sh) if you want to build or test the contract.

```bash
bun install
bun run dev        # start the app on http://localhost:5173
bun run check      # lint and typecheck
npm run build     # production build
bun run contracts:build
bun run contracts:test
```

### Environment variables

All optional for local development. Source defaults point at the Arc Testnet deployment (see `.env.example`). The live Vercel site uses Arc mainnet through the Production and Preview environment variables below; Vite embeds them at build time.

- `VITE_PLUG_CHAIN`: `arc-testnet` (default) or `arc-mainnet`.
- `VITE_PLUG_ADDRESS`: address of the deployed PlugCampaigns contract.
- `VITE_PLUG_DEPLOY_BLOCK`: block the contract was deployed at. Event history is read from here.
- `VITE_DEMO_AGENT_ADDRESS`: payout address of the demo shopping agent.
- `VITE_PLUG_RPC_URL`: use your own RPC endpoint instead of the public Arc one.

Moving to mainnet needs only these variables, no code change: set the chain to `arc-mainnet` and give the mainnet contract address, deploy block and demo agent address.

### Hosting

Deep links such as `/checkout/3` need the host to serve `index.html` for unknown paths. `vercel.json` (Vercel) and `public/_redirects` (Netlify) already do this.

### Contracts

The contract lives in `contracts/PlugCampaigns.sol` with its tests in `contracts/test/`.

- **Current: Plug v2, Arc mainnet (chain 5042):** `0xaa5364de35d65633ad031ff4da4f941e0de6f913` ([contract explorer](https://explorer.arc.io/address/0xaa5364de35d65633ad031ff4da4f941e0de6f913)).
- v2 deploy transaction: https://explorer.arc.io/tx/0x2dd13174e4a4893176bb9782a03ba137c5b5e2a8c3babde2a7b136a7b8a4e5d1 (block `28454210`).
- **Plug v2, Arc Testnet (chain 5042002):** `0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9` ([contract explorer](https://explorer.testnet.arc.io/address/0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9)).
- Earlier version, Plug v1 on Arc mainnet: `0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a` ([contract explorer](https://explorer.arc.io/address/0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a)).
- Earlier version, Plug v1 on Arc Testnet: `0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa` ([contract explorer](https://explorer.testnet.arc.io/address/0xf15c2b5ba701061c926f9c90e191705a1e8fe0aa)).

The v2 mainnet runtime bytecode was verified identical to the tested Arc Studio build.

## Buyer protection in v2

For a protected campaign, the seller picks a **3 to 30 day protection window** in the app and a **public arbiter**. The buyer's USDC price is held in the contract until the buyer confirms or the protection window ends and the order can be released. The seller receives the full price and the agent's commission comes from the seller's budget only when the order settles successfully; instant-settlement campaigns remain available without a protection window.

The buyer can dispute during the protection window. The seller can refund or contest within **3 days**; if the seller does not contest in time, the buyer can claim a refund. The public arbiter decides a contested order within **14 days of the contest**, or the buyer can claim a refund after that deadline. These release and refund paths prevent a seller or inactive arbiter from locking the money forever; the relevant settlement or refund transaction must still be called on-chain.

## Pay-per-sale economics

Plug is pay-per-sale advertising for AI agents on Arc. A seller locks a USDC advertising budget in a campaign. For an instant-settlement purchase, the contract pays the seller the full purchase price and the agent a commission from the seller's campaign budget atomically in the purchase transaction. For a protected order, the buyer's price is escrowed and the commission is reserved until successful settlement, when the seller and agent are paid together. The commission does not reduce the seller's sale proceeds.

For example, when a 10 USDC purchase with a 20% commission settles successfully, the seller receives the full 10 USDC and the agent receives 2 USDC from the seller's advertising budget.

### Why fraud does not pay

Plug pays for completed on-chain purchases, with no payment for impressions or clicks, so click fraud cannot earn a payout. A seller buying from itself only moves its own money. A third party faking a sale must pay the full purchase price and can recover at most 50% as commission, making the fake sale a net loss.

### Sponsored disclosure

Every offer is labelled **Sponsored**. Agents must disclose that an offer is sponsored when recommending it.

## Built with Arc Studio

[Arc Studio project](https://studio.arc.io/app/49ce882a-a246-44f3-a76d-ce91a33aa51a)

Plug v2 contracts and the app were built in Arc Studio. Validation of that build includes **302 Foundry tests, including 10 invariants**, a **max-preset audit**, a **clean Slither result**, and a **53-check end-to-end flow**. These results describe the tested Arc Studio build; they were not rerun as part of this hosting update.

Application and contract changes are made through Arc Studio. Later Arc Studio exports can be committed and pushed as received.

## Deployment links

- Live app: https://plug-tawny.vercel.app
- Public repository: https://github.com/JWattjr/plug
- Current v2 Arc mainnet contract: `0xaa5364de35d65633ad031ff4da4f941e0de6f913`
- v2 Arc mainnet contract explorer: https://explorer.arc.io/address/0xaa5364de35d65633ad031ff4da4f941e0de6f913
- v2 mainnet deploy transaction: https://explorer.arc.io/tx/0x2dd13174e4a4893176bb9782a03ba137c5b5e2a8c3babde2a7b136a7b8a4e5d1
- v2 Arc Testnet contract: `0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9`
- Earlier v1 Arc mainnet contract: `0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a`

The live app uses Arc mainnet. Vercel Production and Preview use the following public build configuration:

| Variable | Value |
| --- | --- |
| `VITE_PLUG_CHAIN` | `arc-mainnet` |
| `VITE_PLUG_ADDRESS` | `0xaa5364de35d65633ad031ff4da4f941e0de6f913` |
| `VITE_PLUG_DEPLOY_BLOCK` | `28454210` |
| `VITE_DEMO_AGENT_ADDRESS` | `0x535df2938c7596497600564b41d0e98a5ea6b13b` |

After changing these variables, rebuild the production deployment without build cache so Vite embeds the new values.

### Build and test

```bash
npm install --legacy-peer-deps
npm run build
forge test
```

The production output is `dist/`. The legacy peer dependency flag accommodates the Vite 6 project and the Vite <=5 peer declaration in `vite-plugin-node-polyfills`. Vercel uses the Vite framework preset, install command `npm install --legacy-peer-deps`, build command `npm run build`, and output directory `dist`. SPA rewrites in `vercel.json` support direct visits to routes such as `/offers` and `/checkout/0`.

## Next steps

Pay-per-impression via Circle Gateway Nanopayments, unlocked only for agents with a proven on-chain sales record. Sub-cent payments per view, with fraud capped by each agent's real conversion rate.
