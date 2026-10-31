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
