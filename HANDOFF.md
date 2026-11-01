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

## Live allowance-read failure after Studio safeguard (2026-11-01)

The user shared the new production error: `Retry allowance check` and `We could not read your USDC allowance from the network` for budget 0.01 USDC. The safeguard is live, but the underlying read failure remains unresolved. Do not request another paid approval.

A read-only snapshot of the actual Chrome Advertise tab showed account `0x535d...b13b`, different from the approved `0xcd64...e289` account. A successful read for that different owner should still produce zero rather than a network error. Console output also showed Phantom/MetaMask competing for `window.ethereum`; this does not establish a cause for wagmi's public HTTP reads. No actual failed RPC payload/response was captured. Native browser inspection ended because Computer Use could not verify the current URL. Follow-up diagnosis and any source changes must go through Arc Studio; actionable error details are needed if the failure cannot be reproduced there.

### Studio follow-up repair and evidence

The follow-up was authored in the same Arc Studio app and thread. Its 15 changed source/test files were pulled unchanged and independently compared byte for byte with the reviewed export. No dependencies, contracts, ABI, deployment addresses, or wallet permissions changed.

The repair tries the configured Arc RPC endpoints, then an unbatched allowance read, then the connected connector's provider using only `eth_chainId` and `eth_call`. A wallet answer is rejected if its reported chain differs from the configured chain. Failed reads remain blocked from paid approvals and expose a copyable diagnostic panel with the owner, target chain, addresses, endpoint host names and redacted errors. The page also identifies the account being checked and its allowance.

Studio reproduced HTTP 429 responses under request bursts and a history scan that repeatedly restarted on failures. The scan now retains progress and reads only new blocks after completion. This is a verified load issue, but the exact cause of the user's failing allowance request remains unproven: that failed request was not captured, and Studio could not launch Chromium. Do not attribute it conclusively to throttling or wallet extensions.

Independent read-only checks against all four Arc endpoints (`rpc.mainnet.arc.io`, `rpc.blockdaemon.mainnet.arc.io`, `rpc.drpc.mainnet.arc.io`, `rpc.quicknode.mainnet.arc.io`) returned chain 5042 and allowance 10000 for `0xcd64...e289`. A separate read for `0x535d...b13b` returned zero. The local regression suite passed 58 tests with 0 failures and 127 assertions; `npm run build` also passed. No real transactions or approvals were sent. Live connected-wallet verification remains necessary after deployment; if it fails, capture the new Technical details panel rather than requesting another approval.

## Confirmed campaign funding; remaining receipt/list read failure (2026-11-01)

The user submitted `createCampaign` through the live app. Transaction https://explorer.arc.io/tx/0xad9b9e9037e81e9b104ee2834c6871a00d055cf8bec405db32e298d7f836a58c succeeded on chain 5042 at block 28995339, from `0xcd64e3b41d523587718da0d5689c9a48a489e289` to the current Plug contract. Decoding with the checkout's ABI confirmed `CampaignCreated` id 0 and one ERC-20 USDC transfer of 10000 raw (0.01 USDC) into Plug. `campaignCount()` is 1 and `getCampaign(0)` returns active=true, title `NCH`, price 0.01 USDC, commission 20%, budgetRemaining 0.01 USDC, instant settlement. The offer URL is a demonstration placeholder, not proof of product delivery. SUBMISSION.md now records this confirmed funding evidence; no further paid transaction is required to repair or verify this UI state.

The actual Chrome tab was connected to the correct owner and successfully read its now-consumed zero allowance through the wallet fallback. Its receipt lookup still failed with `WaitForTransactionReceiptTimeoutError` for the exact successful hash above (browser console timestamp 2026-11-01T13:41:16.301Z, viem 2.57.5). The page showed an unconfirmed notice and an empty/loading My campaigns section. Do not ask the user to approve or create again.

The previous repair was limited to allowance reads. `useTx` and campaign/order/balance/clock reads still relied on the public client; `MyCampaigns` also ignored the campaign query's error. A follow-up was sent directly to the same Studio thread to implement coherent read-only fallback and receipt recovery, prevent duplicate sends for unresolved hashes, and display errors rather than falsely empty campaign lists. No app source was edited manually during diagnosis.

### Shared-read and transaction-recovery repair

Studio completed the follow-up in the same app/thread. All 31 changed source, test and test-configuration files were imported unchanged and compared byte for byte with the reviewed export. The only package.json change extends the test timeout; no dependencies were added. Contracts, ABI, scripts, e2e, public assets, index.html and vite.config.ts were unchanged.

The shared public client now falls back from failed HTTP reads to the actively connected connector using an explicit read-method allowlist and a target-chain check. This covers campaign/order/clock/balance/receipt reads, and recent redacted attempt details remain inspectable even after a fallback succeeds. Campaign and order screens distinguish unread data from a genuinely empty result. Sent transaction hashes are persisted per account, chain, contract and action; unresolved create/approve/buy flows offer read-only status checks and block their send buttons. Confirmed success is retained if a later refresh fails. New pending-hash persistence applies to transactions sent with this build; an older hash was not retroactively stored by the previous version.

Independent local checks passed: 78 tests, 0 failures, 214 assertions across 5 files; `npm run build` passed. The integration regressions mount the real router/layout/pages with failed HTTP reads and a scripted read-only wallet, covering campaign creation and listing, Offers, checkout, retryable errors, wrong-chain rejection, timeout/reload recovery without extra sends, and a confirmed receipt surviving refresh failure. Studio also reported a clean check, but could not run Chromium in its sandbox. No real transaction, approval or deployment was sent by this repair workflow. Live connected-wallet verification remains the final check after publication.

### Completed live check and demo evidence

Production deployment of commit `bbcc334614c7de702a57403cdcd1a241cdb0e366` completed successfully. In the user's actual Chrome browser, connected as `0xcd64...e289`, campaign 0 (`NCH`) appeared in My campaigns, Live offers, and checkout/0. The page showed Arc mainnet, the current Plug contract, a 0.01 USDC remaining campaign budget and 20% commission. The wallet read fallback was active while public HTTP reads failed. No approval or purchase was performed during verification; the user was left on Offers with the campaign visible.

The user supplied the demo video https://youtu.be/7otQT6IlFR8. It has been added to README.md and SUBMISSION.md alongside the confirmed campaign-funding transaction. Purchase/split and refund transaction evidence remain TODO; the video link does not establish that those additional mainnet transactions occurred. The builder profile is still missing, and the grant form has not been submitted.
