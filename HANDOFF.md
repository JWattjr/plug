# Handoff to Claude / Arc Studio

## Dependency review

`npm install --legacy-peer-deps` completed successfully during hosting setup. npm reported 91 dependency vulnerabilities: 12 low, 27 moderate, and 52 high. These are npm audit findings, not a confirmation of exploitability in Plug. Review and resolve dependencies through Arc Studio; no dependency fixes or application changes were made here.

## Build provenance

Application and contract sources must continue to be authored in Arc Studio. This checkout is for documentation, GitHub publication, and Vercel hosting. The unused `scripts/compass-deploy.ts` TypeScript issue is outside the Vite build and is intentionally left unchanged per the build instructions.

## Initial hosting verification (2026-10-25, Arc Testnet)

- Local `npm install --legacy-peer-deps`: passed.
- Local `npx vite build`: passed; output in `dist/`.
- Vercel project: `wattxs-projects/plug`, linked to `JWattjr/plug`, production branch `main`.
- Vercel settings: Vite / `bun install` / `npx vite build` / `dist`.
- No application environment variables configured; Arc Testnet defaults apply.
- The Arc Testnet contract explorer link was opened and verified as a contract on chain 5042002.
- Packaged dependency test keys were excluded from the secrets check with the user's approval; no project credentials or non-example `.env` files are published.
- Public production URL: https://plug-tawny.vercel.app
- Direct browser visit to `/offers`: rendered Live offers and the expected no-live-offers state on Arc Testnet.
- Direct browser visit to `/checkout/0`: rendered the expected campaign-0-does-not-exist state on Arc Testnet.
- Both routes loaded without Vercel authentication; campaign 0 has not been created, so this check does not claim a completed purchase.

## Mainnet hosting update (2026-10-26)

The live site now targets Arc mainnet through Vercel Production and Preview configuration. The initial testnet hosting notes above describe the previous deployment.

- Contract: `0xdfad978d3ef6bb8c88eb765a4e6a514d7c2edd3a`.
- Deploy block: `27934341`.
- Demo agent payout address: `0x535df2938c7596497600564b41d0e98a5ea6b13b`.
- Mainnet contract and deployment transaction links were opened/confirmed on Arc Explorer.
- Application and contract sources remain unchanged; environment changes require a fresh Vite build.

## Plug buyer protection hosting update (2026-10-29)

This update supersedes the earlier v1 live configuration described above.

- Arc Studio buyer protection export committed unchanged as `0eaad62`.
- Current Arc mainnet contract: `0xaa5364de35d65633ad031ff4da4f941e0de6f913`, deploy block `28454210`.
- Production and Preview use `VITE_PLUG_CHAIN=arc-mainnet`, the current contract address/block, and demo agent `0x535df2938c7596497600564b41d0e98a5ea6b13b`.
- Vercel install command: `npm install --legacy-peer-deps`; build command: `npm run build`; output: `dist`.
- A fresh production build succeeded with build cache disabled.
- Browser checks passed for `/`, `/offers`, `/advertise`, `/orders`, `/arbiter`, `/activity`, and `/agent`, including refresh on each route.
- All seven pages showed Arc mainnet and the contract explorer link in the footer; no browser console errors were observed during these checks.
- All 178 protected export files, including AGENTS.md, were verified unchanged during hosting and documentation work.
- The secrets check found no project credentials or non-example environment files. Packaged dependency test fixtures remain excluded with the user's prior approval.
- The remote npm install reported 88 dependency audit findings: 12 low, 24 moderate, and 52 high. Review dependency changes through Arc Studio; no package or app fixes were made here.

## Submission blocker: approval step does not advance (2026-11-01)

The user reports that `/advertise` still shows `Step 1 of 2: Allow 0.01 USDC` after two successful approvals, refreshing, and reconnecting the account that sent those approvals. No campaign has been created. Do not ask the user to approve again or spend another fee until this is resolved through Arc Studio.

### Verified evidence

- Network: Arc mainnet, chain ID `5042`.
- Connected account confirmed by the user: `0xCD64E3B41D523587718dA0D5689C9a48A489e289`.
- Plug contract / spender: `0xaa5364de35d65633ad031ff4da4f941e0de6f913`.
- USDC ERC-20 view: `0x3600000000000000000000000000000000000000`, 6 decimals.
- Both receipts succeeded and decoded as `approve(Plug, 10000)`; neither called `createCampaign`:
  - https://arc.etherscan.io/tx/0x038200e97071447a493620a976e0e0a94a6f7078f7291c1c9a269f69db486786
  - https://arc.etherscan.io/tx/0xf4ef4f18711b1565d345061a151dcdc07c291a17e2051e514dc54fd6d69f5da9
- Latest direct RPC allowance read: `10000` raw = `0.01 USDC`; account balance: `5.683603 USDC` at the check.
- Direct viem reads, explicit Multicall3 reads, and the wagmi public-client defaults all returned the correct allowance. Multicall3 is not established as the cause.
- Vercel Production and Preview variables are the expected mainnet chain/address/block; no `VITE_PLUG_RPC_URL` override is configured. The public RPC used in reproduction was `https://rpc.mainnet.arc.io`.
- Earlier, the site was connected to a different account (`0x535df2938c7596497600564b41d0e98a5ea6b13b`), which legitimately had zero allowance. The user then confirmed reconnecting the approving account above and reported the same approval screen. Investigate the current connected-browser state rather than assuming that the initial account mismatch remains the cause.

### Arc Studio investigation / acceptance criteria

The precise browser-side cause is not yet established; Node RPC checks do not reproduce the reported UI failure. Reproduce with the injected MetaMask account, inspect `useUsdcAllowance` query status/data/error, its owner/spender/network, the browser RPC requests, and the allowance/receipt state transitions in `Advertise` and `useTx`.

`Advertise` currently treats missing allowance data as zero (`allowance.data ?? 0n`) and does not surface the allowance query's loading/error state before offering approval. Prevent unknown or failed reads from encouraging repeated paid approvals. Verify that a successful receipt and an on-chain allowance equal to the budget advance to Create campaign, including after refresh and account switching.

Acceptance: the approving account with allowance `0.01 USDC` and budget `0.01 USDC` sees Create campaign without another approval; failed/loading reads have an explicit non-payment state; campaign creation and receipt handling work from the browser. Build, test, and export any fix through Arc Studio. No protected app or contract files were edited during diagnosis.

## Arc Studio approval-flow fix (2026-11-01)

The user authorized sending the blocker directly to the existing Arc Studio project. Arc Studio authored the changes in app `49ce882a-a246-44f3-a76d-ce91a33aa51a`, thread `21d06d84-bf14-400b-b740-772c0899a987`. The frontend, test dependencies and regression suite were pulled unchanged through the Arc Studio CLI; no contract, ABI, address or deployment settings changed. The npm installer updated package-lock.json to match the Studio-authored package changes.

Confirmed defect: a missing or failed allowance read was treated as zero and could offer an unnecessary paid approval. The shared approval flow now distinguishes loading/error/required/ready states, rechecks immediately before an approval, scopes receipt proof to the chain/token/owner/spender, blocks duplicates after an unconfirmed broadcast, and bounds receipt waiting. Advertise, Checkout and campaign top-ups use the shared safeguard.

Independent local verification: `npx --yes bun@1.3.14 run test` passed 33 tests with 0 failures; `npm run build` passed. The tests use an in-memory chain/wallet and cover the approved 10000 raw / 0.01 budget case, refresh, account switching, failed reads, and failed receipt recovery. React test warnings were non-failing. The tests are outside the existing TypeScript check's configured scope.

Remaining uncertainty: neither Studio nor the local tests reproduced the original failure in the user's actual injected-wallet browser. A browser RPC failure/throttling cause remains unproven. After deployment, ask the user to hard-refresh Advertise with the approving wallet and a 0.01 budget, without paying again. If a read still fails, use the new Retry allowance check state and capture the browser RPC response/error.

No real transactions were sent, no wallets were created, and no mainnet funds were spent by this fix workflow. The user still needs an actual campaign-funding transaction for submission evidence.

The current local npm install reported 89 audit findings (12 low, 18 moderate, 59 high). Dependency review stays inside Arc Studio; no audit-fix mutations were applied locally.
