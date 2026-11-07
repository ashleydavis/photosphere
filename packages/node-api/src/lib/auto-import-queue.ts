//
// The auto-import pacing moved into `packages/api` so the mobile frontend can reach it. See the
// comment in `media-source.ts` beside this file for why. Nothing in the pacing was Node-specific:
// it touches no filesystem, no queue and no clock.
//
export * from "api/src/lib/auto-import-queue";
