## Plug

Plug is pay-per-sale advertising for AI agents on Arc, with buyer protection: sponsored referrals earn commissions only on successfully settled purchases. Plug uses Arc for USDC campaign budgets, protected-order escrow, and atomic settlement that pays the seller the full purchase price and the agent a commission from the seller's separate advertising budget. The contracts, tests, audit and application were built in Arc Studio.

## How it works

1. A seller creates an offer and locks a USDC commission budget.
2. An agent reads the live offers, discloses that its recommendation is sponsored, and shares a referral checkout link.
3. When an instant-settlement purchase succeeds, the contract pays the seller the full price and pays the agent from the campaign budget in the same transaction. Protected orders settle after the escrow conditions are met.
4. Sellers can top up campaigns or end them and reclaim unspent advertising budgets.

There are no payments for impressions or clicks. Clicks cannot generate a payout. A seller buying from itself only moves its own money; a third party faking a sale must pay the full price and can recover at most 50% as commission. Every offer is labelled Sponsored.

## Buyer protection

Sellers choose a protection window of 3 to 30 days in the app and a public arbiter. The buyer's price is held in escrow until confirmation or an eligible release. Buyers can dispute; sellers can refund or contest within 3 days. The arbiter has 14 days from a contest to decide, after which the buyer can claim a refund. Timed release and refund paths prevent inactivity from locking funds indefinitely; the relevant on-chain transaction is required to exercise each path.

## Built with Arc Studio

Project: https://studio.arc.io/app/49ce882a-a246-44f3-a76d-ce91a33aa51a

The contract build passed 302 Foundry tests including 10 invariants, a max-preset Arc Studio audit, clean Slither checks, and a 53-check end-to-end flow. The mainnet runtime bytecode was verified identical to the tested build. The application also has 78 passing frontend regressions, including failed-RPC recovery and transaction-status recovery using a fake chain and scripted wallet. Application and contract changes are authored through Arc Studio.

## Verified Arc mainnet demonstration

Network: Arc mainnet, chain ID 5042.

Contract: 0xaa5364de35d65633ad031ff4da4f941e0de6f913
Contract explorer: https://explorer.arc.io/address/0xaa5364de35d65633ad031ff4da4f941e0de6f913

Campaign creation and USDC funding transaction:
https://explorer.arc.io/tx/0xad9b9e9037e81e9b104ee2834c6871a00d055cf8bec405db32e298d7f836a58c

This successful transaction created campaign #0 (NCH) and funded its advertising budget with 0.01 real USDC. The demonstration offer has a 0.01 USDC price, 20% commission and instant settlement. The live campaign is visible in My campaigns, Offers and Checkout. This is a demonstration offer; the mainnet evidence shown is campaign creation and budget funding.

Deployment transaction:
https://explorer.arc.io/tx/0x2dd13174e4a4893176bb9782a03ba137c5b5e2a8c3babde2a7b136a7b8a4e5d1

Demo video: https://youtu.be/7otQT6IlFR8
Live app: https://plug-tawny.vercel.app
Public repository: https://github.com/JWattjr/plug
Builder profile: https://dorahacks.io/builder/runexbt

## Tech stack

Solidity, Foundry, OpenZeppelin, React, TypeScript, Vite, wagmi and viem. The app includes sponsored offer JSON for agents, a demo shopping agent, referral checkout, campaign management, protected orders, arbiter decisions, activity and earnings views.

## Next step

Pay-per-impression via Circle Gateway Nanopayments, unlocked only for agents with a proven on-chain sales record. Sub-cent payments per view, with fraud capped by each agent's real conversion rate.
