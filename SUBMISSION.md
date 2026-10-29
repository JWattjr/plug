# Plug - Arc Microgrants Round 2

- Arc Studio project URL: https://studio.arc.io/app/49ce882a-a246-44f3-a76d-ce91a33aa51a
- Live app URL: https://plug-tawny.vercel.app
- Public repo URL: https://github.com/JWattjr/plug
- Contract address (Arc mainnet, current Plug v2): `0xaa5364de35d65633ad031ff4da4f941e0de6f913`
- Arc mainnet contract explorer: https://explorer.arc.io/address/0xaa5364de35d65633ad031ff4da4f941e0de6f913
- Deploy tx: https://explorer.arc.io/tx/0x2dd13174e4a4893176bb9782a03ba137c5b5e2a8c3babde2a7b136a7b8a4e5d1
- Example mainnet txs (explorer.arc.io links):
  - Create campaign: TODO
  - Purchase with seller/agent split: TODO
  - End campaign refund: TODO
- Video walkthrough: TODO
- Builder profile: TODO

## Description (3 sentences)

Plug v2 is pay-per-sale advertising for AI agents with buyer protection: sponsored referrals earn commissions only on successfully settled purchases. Plug uses Arc for USDC campaign budgets, protected-order escrow, and atomic settlement that pays the seller the full price and the agent a commission from the seller's advertising budget. Arc Studio built the contracts and app, with 302 Foundry tests including 10 invariants, a max-preset audit, clean Slither results, and a 53-check end-to-end flow.

## Buyer protection

The seller chooses a 3 to 30 day protection window in the app and a public arbiter. The buyer's price stays in escrow until the buyer confirms or the protection window ends and the order can be released. A buyer can dispute; the seller can refund or contest within 3 days, and an uncontested dispute can be refunded after that deadline. The arbiter decides a contested order within 14 days of the contest, or the buyer can claim a refund. Deadline-based release and refund paths prevent an inactive seller or arbiter from locking the money forever; a transaction is required to exercise the appropriate path.

## Build verification and earlier version

- Current v2 deploy block: `28454210`.
- The v2 mainnet runtime bytecode was verified identical to the tested Arc Studio build.
- Earlier version, v1 Arc mainnet contract: `0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a` ([contract explorer](https://explorer.arc.io/address/0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a)).

## Additional testnet evidence

- Arc Testnet v2 contract address: `0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9` (chain ID 5042002)
- Arc Testnet contract explorer: https://explorer.testnet.arc.io/address/0x2e90b00fe5b9289b2aa1e37ac8b5f8e9afb6ffd9

The mainnet contract and deploy transaction are linked above. The three demo transactions, video walkthrough, and builder profile remain TODO. This document is a submission draft; no grant form has been submitted.
