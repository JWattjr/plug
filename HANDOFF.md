# Handoff to Claude / Arc Studio

## Dependency review

`npm install --legacy-peer-deps` completed successfully during hosting setup. npm reported 91 dependency vulnerabilities: 12 low, 27 moderate, and 52 high. These are npm audit findings, not a confirmation of exploitability in Plug. Review and resolve dependencies through Arc Studio; no dependency fixes or application changes were made here.

## Build provenance

Application and contract sources must continue to be authored in Arc Studio. This checkout is for documentation, GitHub publication, and Vercel hosting. The unused `scripts/compass-deploy.ts` TypeScript issue is outside the Vite build and is intentionally left unchanged per the build instructions.
